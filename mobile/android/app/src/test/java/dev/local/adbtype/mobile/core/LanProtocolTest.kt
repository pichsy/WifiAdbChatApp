package dev.local.adbtype.mobile.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class LanProtocolTest {

    @Test
    fun helloWithoutCodeOmitsCodeField() {
        val hello = LanProtocol.hello("id-1", "手机", null)
        assertEquals("ADBTypeLink", hello["app"])
        assertEquals(1, hello["v"])
        assertEquals("id-1", hello["id"])
        assertEquals("手机", hello["name"])
        assertFalse(hello.containsKey("code"))
    }

    @Test
    fun helloWithCodeTrimsWhitespace() {
        val hello = LanProtocol.hello("id-1", "手机", " 123456 ")
        assertEquals("123456", hello["code"])
    }

    @Test
    fun helloWithBlankCodeOmitsField() {
        val hello = LanProtocol.hello("id-1", "手机", "   ")
        assertFalse(hello.containsKey("code"))
    }

    @Test
    fun contentMessagesHaveExpectedShape() {
        assertEquals("text", LanProtocol.text("hi")["type"])
        assertEquals("hi", LanProtocol.text("hi")["text"])
        val file = LanProtocol.file("a.txt", 2048L)
        assertEquals("file", file["type"])
        assertEquals("a.txt", file["name"])
        assertEquals(2048L, file["size"])
        assertEquals("ok", LanProtocol.ok()["type"])
        assertEquals("bye", LanProtocol.bye()["type"])
        assertEquals("hello_ok", LanProtocol.helloOk("me", "手机")["type"])
        assertEquals("phone", LanProtocol.helloOk("me", "phone")["name"])
        assertEquals("pair_required", LanProtocol.pairRequired("手机")["type"])
        assertEquals("error", LanProtocol.error("boom")["type"])
        assertEquals("boom", LanProtocol.error("boom")["message"])
    }

    @Test
    fun announcementRoundTrip() {
        val payload = LanProtocol.announcement("device-1", "电脑", 45678)
        assertNotNull(payload)
        val parsed = AnnouncementParser.parse(payload, "self-id")
        assertNotNull(parsed)
        assertEquals("device-1", parsed?.deviceId)
        assertEquals("电脑", parsed?.name)
        assertEquals(45678, parsed?.port)
        assertEquals(1, parsed?.version)
    }

    @Test
    fun announcementRejectsInvalidFields() {
        // app 不对
        assertNull(AnnouncementParser.parse(payload("OtherApp", "id-2", "名字", 1234), "self"))
        // 自己
        assertNull(AnnouncementParser.parse(payload("ADBTypeLink", "self", "名字", 1234), "self"))
        // 空名字
        assertNull(AnnouncementParser.parse(payload("ADBTypeLink", "id-2", "", 1234), "self"))
        // 端口越界
        assertNull(AnnouncementParser.parse(payload("ADBTypeLink", "id-2", "名字", 0), "self"))
        assertNull(AnnouncementParser.parse(payload("ADBTypeLink", "id-2", "名字", 70000), "self"))
        // 非法 JSON
        assertNull(AnnouncementParser.parse("not json".toByteArray(), "self"))
        assertNull(AnnouncementParser.parse(null, "self"))
    }

    @Test
    fun announcementAcceptsNewerProtocolVersion() {
        val payload = ("{\"app\":\"ADBTypeLink\",\"v\":2,\"id\":\"id-2\","
            + "\"name\":\"电脑\",\"port\":1234}").toByteArray(Charsets.UTF_8)
        val parsed = AnnouncementParser.parse(payload, "self")
        assertEquals(2, parsed?.version)
    }

    @Test
    fun announcementRequiresPort() {
        val payload = ("{\"app\":\"ADBTypeLink\",\"v\":1,\"id\":\"id-2\",\"name\":\"电脑\"}")
            .toByteArray(Charsets.UTF_8)
        assertNull(AnnouncementParser.parse(payload, "self"))
    }

    @Test
    fun handshakeInterpreterHandlesAllResponses() {
        val ok = HandshakeInterpreter.interpret(
            LanProtocol.helloOk("peer-1", "电脑"), "fallback-id", "fallback-name",
        )
        assertTrue(ok is HandshakeOutcome.Ok)
        assertEquals("peer-1", (ok as HandshakeOutcome.Ok).peerId)
        assertEquals("电脑", ok.peerName)

        val needsPairing = HandshakeInterpreter.interpret(LanProtocol.pairRequired("电脑"), "id", "name")
        assertTrue(needsPairing is HandshakeOutcome.NeedsPairing)
        assertEquals("电脑", (needsPairing as HandshakeOutcome.NeedsPairing).peerName)

        val failure = HandshakeInterpreter.interpret(LanProtocol.error("协议不匹配，请升级两端应用"), "id", "name")
        assertTrue(failure is HandshakeOutcome.Failure)
        assertEquals("协议不匹配，请升级两端应用", (failure as HandshakeOutcome.Failure).message)

        val noResponse = HandshakeInterpreter.interpret(null, "id", "name")
        assertTrue(noResponse is HandshakeOutcome.Failure)
        assertEquals("对方没有响应", (noResponse as HandshakeOutcome.Failure).message)

        val unknown = HandshakeInterpreter.interpret(linkedMapOf("type" to "whatever"), "id", "name")
        assertTrue(unknown is HandshakeOutcome.Failure)
        assertEquals("协议不匹配，请确认两端版本一致", (unknown as HandshakeOutcome.Failure).message)
    }

    private fun payload(app: String, id: String, name: String, port: Int): ByteArray {
        val map = linkedMapOf<String, Any?>(
            "app" to app,
            "v" to 1,
            "id" to id,
            "name" to name,
            "port" to port,
        )
        return LanJson.stringify(map).toByteArray(Charsets.UTF_8)
    }
}
