package dev.local.adbtype.mobile.core

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 端到端协议流（不碰网络 socket）：把自己的帧写进字节流，另一端按真实逻辑解析，
 * 验证「帧编解码 + 握手 + 配对判断 + 文件头/原始字节」组合起来是通的。
 */
class ProtocolFlowTest {

    @Test
    fun firstPairingHandshakeWithCorrectCode() {
        val clientOut = ByteArrayOutputStream()
        LanFrame.writeFrame(clientOut, LanProtocol.hello("android-1", "手机", "123456"))

        val hello = LanFrame.readFrame(ByteArrayInputStream(clientOut.toByteArray()))
        val decision = PairingPolicy.evaluateHello(
            hello = hello,
            selfId = "mac-1",
            currentCode = "123456",
            pairedPeerIds = emptySet(),
        )
        assertTrue(decision is HelloDecision.Accept)

        val serverOut = ByteArrayOutputStream()
        LanFrame.writeFrame(serverOut, LanProtocol.helloOk("mac-1", "MacBook Pro"))
        val response = LanFrame.readFrame(ByteArrayInputStream(serverOut.toByteArray()))
        val outcome = HandshakeInterpreter.interpret(response, "mac-1", "MacBook Pro")
        assertTrue(outcome is HandshakeOutcome.Ok)
        assertEquals("mac-1", (outcome as HandshakeOutcome.Ok).peerId)
    }

    @Test
    fun wrongCodeProducesPairRequired() {
        val clientOut = ByteArrayOutputStream()
        LanFrame.writeFrame(clientOut, LanProtocol.hello("android-1", "手机", "000000"))
        val hello = LanFrame.readFrame(ByteArrayInputStream(clientOut.toByteArray()))
        val decision = PairingPolicy.evaluateHello(hello, "mac-1", "123456", emptySet())
        assertTrue(decision is HelloDecision.NeedsPairing)

        val serverOut = ByteArrayOutputStream()
        LanFrame.writeFrame(serverOut, LanProtocol.pairRequired("MacBook Pro"))
        val response = LanFrame.readFrame(ByteArrayInputStream(serverOut.toByteArray()))
        val outcome = HandshakeInterpreter.interpret(response, "mac-1", "MacBook Pro")
        assertTrue(outcome is HandshakeOutcome.NeedsPairing)
    }

    @Test
    fun pairedPeerSkipsPairingCode() {
        val clientOut = ByteArrayOutputStream()
        LanFrame.writeFrame(clientOut, LanProtocol.hello("android-1", "手机", null))
        val hello = LanFrame.readFrame(ByteArrayInputStream(clientOut.toByteArray()))
        val decision = PairingPolicy.evaluateHello(hello, "mac-1", "123456", setOf("android-1"))
        assertTrue(decision is HelloDecision.Accept)
        assertTrue((decision as HelloDecision.Accept).alreadyPaired)
    }

    @Test
    fun textMessageRoundTrip() {
        val text = "你好，电脑！🎉 这是中文和 emoji"
        val clientOut = ByteArrayOutputStream()
        LanFrame.writeFrame(clientOut, LanProtocol.text(text))
        val decoded = LanFrame.readFrame(ByteArrayInputStream(clientOut.toByteArray()))
        assertEquals("text", decoded?.stringValue("type"))
        assertEquals(text, decoded?.stringValue("text"))
    }

    @Test
    fun fileHeaderFollowedByRawBytes() {
        val payload = ByteArray(300_000) { (it % 256).toByte() }
        val output = ByteArrayOutputStream()
        LanFrame.writeFrame(output, LanProtocol.file("报告 v2.pdf", payload.size.toLong()))
        output.write(payload)

        val input = ByteArrayInputStream(output.toByteArray())
        val header = LanFrame.readFrame(input)
        assertEquals("file", header?.stringValue("type"))
        assertEquals("报告 v2.pdf", header?.stringValue("name"))
        assertEquals(payload.size.toLong(), header?.longValue("size"))

        val received = LanFrame.readFully(input, header!!.intValue("size")!!)
        assertArrayEquals(payload, received!!)
    }
}
