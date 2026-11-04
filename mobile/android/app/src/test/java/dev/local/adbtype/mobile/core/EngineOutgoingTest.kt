package dev.local.adbtype.mobile.core

import java.io.File
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.ServerSocket
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/**
 * 真实 socket 联调（发送方向）：
 * 假对端用 UDP 广播把自己「通告」给引擎，引擎发现后通过 TCP 发文字和文件，
 * 假对端按协议回应 ok/bye —— 覆盖「发现 → 连接 → 握手 → 发送 → 确认」整条链路。
 */
class EngineOutgoingTest {

    @get:Rule
    val temp = TemporaryFolder()

    private lateinit var engine: LanEngine
    private lateinit var root: File

    private val listener = object : LanEngineListener {
        override fun onLanChanged() = Unit
    }

    @Before
    fun setUp() {
        root = temp.newFolder("engine-outgoing")
        engine = LanEngine(
            stores = LanStores(File(root, "lan")),
            receivedFilePublisher = DirectoryReceivedFilePublisher({ File(root, "received") }, "下载/文件互传助手"),
            deviceNameProvider = { "测试手机" },
            listener = listener,
            discoveryPort = freeUdpPort(),
        )
        engine.start()
        assumeTrue("本机 UDP/TCP 监听启动失败，跳过 socket 集成测试", engine.listeningPort() in 1..65535)
        assumeTrue("UDP 52730 不可用（可能被占用），跳过发现方向测试", engine.snapshot().discoveryError == null)
    }

    @After
    fun tearDown() {
        if (::engine.isInitialized) engine.stop()
    }

    @Test
    fun discoversPeerThenSendsTextAndFile() {
        val peerId = "fake-peer-1"
        val server = ServerSocket(0)
        server.soTimeout = 10_000
        val receivedHello = AtomicReference<Map<String, Any?>?>(null)
        val receivedText = AtomicReference<String?>(null)
        val receivedFileName = AtomicReference<String?>(null)
        val receivedFileBytes = AtomicReference<ByteArray?>(null)
        val peerError = AtomicReference<Throwable?>(null)

        val peerThread = Thread {
            try {
                for (round in 0 until 2) {
                    server.accept().use { socket ->
                        socket.soTimeout = 10_000
                        val input = socket.getInputStream()
                        val output = socket.getOutputStream()
                        val hello = LanFrame.readFrame(input)
                        receivedHello.set(hello)
                        LanFrame.writeFrame(output, LanProtocol.helloOk(peerId, "Python 对端"))
                        when (val frame = LanFrame.readFrame(input)) {
                            null -> throw IllegalStateException("没有收到内容帧")
                            else -> when (frame.stringValue("type")) {
                                "text" -> {
                                    receivedText.set(frame.stringValue("text"))
                                    LanFrame.writeFrame(output, LanProtocol.ok())
                                }
                                "file" -> {
                                    receivedFileName.set(frame.stringValue("name"))
                                    val size = frame.intValue("size") ?: 0
                                    receivedFileBytes.set(LanFrame.readFully(input, size))
                                    LanFrame.writeFrame(output, LanProtocol.ok())
                                }
                                else -> throw IllegalStateException("未知内容帧：" + frame.stringValue("type"))
                            }
                        }
                        LanFrame.readFrame(input) // bye
                    }
                }
            } catch (error: Throwable) {
                peerError.set(error)
            }
        }
        peerThread.isDaemon = true
        peerThread.start()

        try {
            announcePeer(peerId, server.localPort)
            waitFor("引擎没有通过 UDP 发现假对端") { snapshot -> snapshot.nearby.any { it.id == peerId } }

            val textLatch = CountDownLatch(1)
            val textResult = AtomicReference<SendResult?>(null)
            engine.sendText(peerId, "你好，电脑！🎉", null) { result ->
                textResult.set(result)
                textLatch.countDown()
            }
            assertTrue("发送文字超时", textLatch.await(10, TimeUnit.SECONDS))
            assertTrue("发送文字失败：" + textResult.get(), textResult.get() is SendResult.Success)

            val file = File(root, "测试文件.txt")
            file.writeText("文件内容 😀", Charsets.UTF_8)
            val fileLatch = CountDownLatch(1)
            val fileResult = AtomicReference<SendResult?>(null)
            engine.sendFiles(
                peerId,
                listOf(OutgoingFile(file, file.name, file.length())),
                null,
            ) { result ->
                fileResult.set(result)
                fileLatch.countDown()
            }
            assertTrue("发送文件超时", fileLatch.await(10, TimeUnit.SECONDS))
            assertTrue("发送文件失败：" + fileResult.get(), fileResult.get() is SendResult.Success)

            peerThread.join(5_000)
            assertEquals(null, peerError.get())

            val hello = receivedHello.get()
            assertEquals("ADBTypeLink", hello?.stringValue("app"))
            assertEquals("测试手机", hello?.stringValue("name"))
            assertEquals("你好，电脑！🎉", receivedText.get())
            assertEquals("测试文件.txt", receivedFileName.get())
            assertArrayEquals("文件内容 😀".toByteArray(Charsets.UTF_8), receivedFileBytes.get())

            val snapshot = waitFor("引擎没有记录发出的消息") { it.conversations[peerId]?.size == 2 }
            assertTrue(snapshot.pairedIds.contains(peerId))
            assertTrue(snapshot.friends.any { it.id == peerId })
        } finally {
            server.close()
        }
    }

    private fun announcePeer(peerId: String, tcpPort: Int) {
        val payload = LanProtocol.announcement(peerId, "Python 对端", tcpPort)
            ?: throw IllegalStateException("构造通告失败")
        DatagramSocket().use { socket ->
            val address = InetAddress.getByName("127.0.0.1")
            socket.send(DatagramPacket(payload, payload.size, address, engine.discoveryPortValue()))
        }
    }

    private fun freeUdpPort(): Int = DatagramSocket(0).use { it.localPort }

    private fun waitFor(message: String, timeoutMs: Long = 5_000, predicate: (LanSnapshot) -> Boolean): LanSnapshot {
        val deadline = System.currentTimeMillis() + timeoutMs
        var snapshot = engine.snapshot()
        while (System.currentTimeMillis() < deadline) {
            if (predicate(snapshot)) return snapshot
            Thread.sleep(25)
            snapshot = engine.snapshot()
        }
        assertTrue(message, predicate(snapshot))
        return snapshot
    }
}
