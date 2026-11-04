package dev.local.adbtype.mobile.core

import java.io.File
import java.net.Socket
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/**
 * 真实 socket 联调（接收方向）：起一个 LanEngine，用裸 TCP 客户端模拟电脑端，
 * 走一遍 hello → hello_ok → text/file → ok → bye 的完整服务端流程。
 */
class EngineIncomingTest {

    @get:Rule
    val temp = TemporaryFolder()

    private lateinit var engine: LanEngine
    private lateinit var receivedDir: File

    private val listener = object : LanEngineListener {
        override fun onLanChanged() {
            // 测试里用轮询取快照，回调只用于触发
        }
    }

    @Before
    fun setUp() {
        val root = temp.newFolder("engine-incoming")
        receivedDir = File(root, "received")
        engine = LanEngine(
            stores = LanStores(File(root, "lan")),
            receivedFilePublisher = DirectoryReceivedFilePublisher({ receivedDir }, "下载/文件互传助手"),
            deviceNameProvider = { "测试手机" },
            listener = listener,
            discoveryPort = freeUdpPort(),
        )
        engine.start()
        assumeTrue("本机 TCP 监听启动失败，跳过 socket 集成测试", engine.listeningPort() in 1..65535)
    }

    @After
    fun tearDown() {
        if (::engine.isInitialized) engine.stop()
    }

    @Test
    fun correctPairingCodeThenTextThenFile() {
        val payload = ByteArray(1500) { (it % 251).toByte() }
        Socket("127.0.0.1", engine.listeningPort()).use { socket ->
            socket.soTimeout = 5_000
            val input = socket.getInputStream()
            val output = socket.getOutputStream()

            LanFrame.writeFrame(output, LanProtocol.hello("test-peer-1", "电脑对端", engine.currentPairingCode()))
            val helloOk = LanFrame.readFrame(input)
            assertEquals("hello_ok", helloOk?.stringValue("type"))
            assertEquals("测试手机", helloOk?.stringValue("name"))

            LanFrame.writeFrame(output, LanProtocol.text("你好 😀 中文 emoji"))
            assertEquals("ok", LanFrame.readFrame(input)?.stringValue("type"))

            // 路径穿越的文件名只保留最后一段
            LanFrame.writeFrame(output, LanProtocol.file("../evil (2).bin", payload.size.toLong()))
            output.write(payload)
            assertEquals("ok", LanFrame.readFrame(input)?.stringValue("type"))

            LanFrame.writeFrame(output, LanProtocol.bye())
        }

        val snapshot = waitFor("引擎没有收到文字/文件") { it.conversations["test-peer-1"]?.size == 2 }
        val messages = snapshot.conversations["test-peer-1"] ?: emptyList()
        assertEquals(ChatKind.TEXT, messages[0].kind)
        assertEquals("你好 😀 中文 emoji", messages[0].text)
        assertEquals(ChatKind.FILE, messages[1].kind)
        assertEquals("evil (2).bin", messages[1].fileName)
        assertEquals(payload.size.toLong(), messages[1].fileSize)

        val saved = File(receivedDir, "evil (2).bin")
        assertTrue("接收文件应落盘", saved.isFile)
        assertArrayEquals(payload, saved.readBytes())
        assertEquals("消息应记录文件路径", saved.absolutePath, messages[1].filePath)
        assertEquals(null, messages[1].fileUri)
        assertEquals("下载/文件互传助手", snapshot.receiveLocationLabel)
        assertTrue("配对码正确后应记住对方 ID", snapshot.pairedIds.contains("test-peer-1"))
        assertEquals(1, snapshot.friends.count { it.id == "test-peer-1" })
    }

    @Test
    fun wrongPairingCodeAsksForPairing() {
        Socket("127.0.0.1", engine.listeningPort()).use { socket ->
            socket.soTimeout = 5_000
            val input = socket.getInputStream()
            val output = socket.getOutputStream()
            LanFrame.writeFrame(output, LanProtocol.hello("test-peer-2", "电脑对端", wrongCode()))
            assertEquals("pair_required", LanFrame.readFrame(input)?.stringValue("type"))
        }
        val snapshot = waitFor("引擎没有记录配对请求") { it.pairingRequest?.peerId == "test-peer-2" }
        assertFalse(snapshot.pairedIds.contains("test-peer-2"))
        assertEquals("电脑对端", snapshot.pairingRequest?.peerName)
    }

    @Test
    fun missingPairingCodeAsksForPairing() {
        Socket("127.0.0.1", engine.listeningPort()).use { socket ->
            socket.soTimeout = 5_000
            val input = socket.getInputStream()
            val output = socket.getOutputStream()
            LanFrame.writeFrame(output, LanProtocol.hello("test-peer-3", "电脑对端", null))
            assertEquals("pair_required", LanFrame.readFrame(input)?.stringValue("type"))
        }
    }

    @Test
    fun invalidHelloGetsProtocolError() {
        Socket("127.0.0.1", engine.listeningPort()).use { socket ->
            socket.soTimeout = 5_000
            val input = socket.getInputStream()
            val output = socket.getOutputStream()
            LanFrame.writeFrame(output, linkedMapOf("type" to "hello", "app" to "OtherApp", "id" to "x", "name" to "y"))
            val response = LanFrame.readFrame(input)
            assertEquals("error", response?.stringValue("type"))
            assertTrue(response?.stringValue("message")?.isNotBlank() == true)
        }
    }

    private fun freeUdpPort(): Int = java.net.DatagramSocket(0).use { it.localPort }

    private fun wrongCode(): String {
        val current = engine.currentPairingCode().toIntOrNull() ?: 0
        val wrong = (current + 1) % 1_000_000
        return String.format(java.util.Locale.ROOT, "%06d", wrong)
    }

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
