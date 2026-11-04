package dev.local.adbtype.mobile.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.random.Random

class PairingTest {

    @Test
    fun generatedCodeIsSixDigits() {
        repeat(300) {
            val code = PairingCode.generate()
            assertEquals(6, code.length)
            assertTrue(code.all { char -> char in '0'..'9' })
            assertNotNull(PairingCode.normalize(code))
        }
    }

    @Test
    fun generatedCodeAcceptsSeededRandom() {
        val code = PairingCode.generate(Random(1234))
        assertEquals(6, code.length)
        assertTrue(code.all { it in '0'..'9' })
    }

    @Test
    fun normalizeRequiresExactlySixDigits() {
        assertEquals("123456", PairingCode.normalize("123456"))
        assertEquals("123456", PairingCode.normalize("  123456  "))
        assertEquals("000123", PairingCode.normalize("000123"))
        assertNull(PairingCode.normalize("12345"))
        assertNull(PairingCode.normalize("1234567"))
        assertNull(PairingCode.normalize("12345a"))
        assertNull(PairingCode.normalize(""))
        assertNull(PairingCode.normalize("   "))
        assertNull(PairingCode.normalize(null))
    }

    @Test
    fun matchesTrimsWhitespaceButRequiresExactValue() {
        assertTrue(PairingCode.matches("123456", "123456"))
        assertTrue(PairingCode.matches(" 123456 ", "123456"))
        assertTrue(PairingCode.matches("000123", "000123"))
        assertFalse(PairingCode.matches("654321", "123456"))
        assertFalse(PairingCode.matches(null, "123456"))
        assertFalse(PairingCode.matches("", "123456"))
        assertFalse(PairingCode.matches("1234567", "123456"))
    }

    @Test
    fun alreadyPairedPeerIsAcceptedWithoutCode() {
        val decision = PairingPolicy.evaluateHello(
            hello = hello(id = "peer-1", code = null),
            selfId = "self",
            currentCode = "123456",
            pairedPeerIds = setOf("peer-1"),
        )
        assertTrue(decision is HelloDecision.Accept)
        decision as HelloDecision.Accept
        assertEquals("peer-1", decision.peerId)
        assertEquals("电脑", decision.peerName)
        assertTrue(decision.alreadyPaired)
    }

    @Test
    fun correctCodeIsAcceptedAndNeedsPersistence() {
        val decision = PairingPolicy.evaluateHello(
            hello = hello(id = "peer-1", code = "123456"),
            selfId = "self",
            currentCode = "123456",
            pairedPeerIds = emptySet(),
        )
        assertTrue(decision is HelloDecision.Accept)
        assertFalse((decision as HelloDecision.Accept).alreadyPaired)
    }

    @Test
    fun codeWithSurroundingSpacesIsAccepted() {
        val decision = PairingPolicy.evaluateHello(
            hello = hello(id = "peer-1", code = "  123456\t"),
            selfId = "self",
            currentCode = "123456",
            pairedPeerIds = emptySet(),
        )
        assertTrue(decision is HelloDecision.Accept)
    }

    @Test
    fun wrongOrMissingCodeRequestsPairing() {
        val missing = PairingPolicy.evaluateHello(
            hello = hello(id = "peer-1", code = null),
            selfId = "self",
            currentCode = "123456",
            pairedPeerIds = emptySet(),
        )
        assertTrue(missing is HelloDecision.NeedsPairing)
        assertEquals("peer-1", (missing as HelloDecision.NeedsPairing).peerId)

        val wrong = PairingPolicy.evaluateHello(
            hello = hello(id = "peer-2", code = "654321"),
            selfId = "self",
            currentCode = "123456",
            pairedPeerIds = emptySet(),
        )
        assertTrue(wrong is HelloDecision.NeedsPairing)
        assertEquals("电脑", (wrong as HelloDecision.NeedsPairing).peerName)
    }

    @Test
    fun invalidHelloIsRejected() {
        assertTrue(PairingPolicy.evaluateHello(null, "self", "123456", emptySet()) is HelloDecision.Reject)
        assertTrue(
            PairingPolicy.evaluateHello(
                hello(app = "OtherApp"), "self", "123456", emptySet(),
            ) is HelloDecision.Reject
        )
        assertTrue(
            PairingPolicy.evaluateHello(
                hello(id = "self"), "self", "123456", emptySet(),
            ) is HelloDecision.Reject
        )
        assertTrue(
            PairingPolicy.evaluateHello(
                hello(name = ""), "self", "123456", emptySet(),
            ) is HelloDecision.Reject
        )
        val missingId = hello()
        missingId.remove("id")
        assertTrue(PairingPolicy.evaluateHello(missingId, "self", "123456", emptySet()) is HelloDecision.Reject)
    }

    @Test
    fun rejectMessageMatchesMac() {
        val decision = PairingPolicy.evaluateHello(null, "self", "123456", emptySet())
        assertEquals("协议不匹配，请升级两端应用", (decision as HelloDecision.Reject).message)
    }

    private fun hello(
        app: String = "ADBTypeLink",
        id: String = "peer-1",
        name: String = "电脑",
        code: String? = null,
    ): MutableMap<String, Any?> {
        val map = linkedMapOf<String, Any?>(
            "app" to app,
            "v" to 1,
            "id" to id,
            "name" to name,
        )
        if (code != null) map["code"] = code
        return map
    }
}
