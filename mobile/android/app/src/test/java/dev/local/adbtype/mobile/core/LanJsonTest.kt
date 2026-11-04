package dev.local.adbtype.mobile.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class LanJsonTest {

    @Test
    fun parsesObjectWithMixedTypes() {
        val parsed = LanJson.parse("""{"app":"ADBTypeLink","v":1,"ok":true,"none":null,"list":[1,2,3]}""")
        val obj = parsed.asJsonObject()
        assertEquals("ADBTypeLink", obj?.stringValue("app"))
        assertEquals(1L, obj?.longValue("v"))
        assertEquals(true, obj?.booleanValue("ok"))
        assertTrue(obj?.containsKey("none") == true)
        assertNull(obj?.get("none"))
        assertEquals(3, obj?.get("list").asJsonArray()?.size)
    }

    @Test
    fun integersBecomeLongAndDecimalsBecomeDouble() {
        val parsed = LanJson.parse("""{"size":1048576,"ratio":1.5,"exp":1e3}""").asJsonObject()
        assertEquals(1048576L, parsed?.get("size"))
        assertEquals(1.5, parsed?.get("ratio"))
        assertEquals(1000.0, parsed?.get("exp"))
    }

    @Test
    fun parsesUnicodeEscapesAndEmoji() {
        val parsed = LanJson.parse("""{"text":"\u4f60\u597d \ud83d\ude00"}""").asJsonObject()
        assertEquals("你好 😀", parsed?.stringValue("text"))
    }

    @Test
    fun stringifyThenParseKeepsChineseAndEmoji() {
        val message = linkedMapOf<String, Any?>(
            "type" to "text",
            "text" to "中文 / emoji 😀🎉 / \"引号\" / 换行\n结束",
        )
        val json = LanJson.stringify(message)
        val parsed = LanJson.parse(json).asJsonObject()
        assertEquals(message["text"], parsed?.stringValue("text"))
    }

    @Test
    fun stringifyEscapesControlCharacters() {
        val json = LanJson.stringify("a\u0001b")
        assertTrue(json.contains("\\u0001"))
        assertEquals("a\u0001b", LanJson.parse(json))
    }

    @Test
    fun parseOrNullReturnsNullForBrokenJson() {
        assertNull(LanJson.parseOrNull("{"))
        assertNull(LanJson.parseOrNull("不是 JSON"))
        assertNull(LanJson.parseOrNull(""))
        assertNull(LanJson.parseOrNull(null))
        assertNull(LanJson.parseOrNull("""{"a":1} extra"""))
    }

    @Test(expected = LanJsonException::class)
    fun parseThrowsForTrailingContent() {
        LanJson.parse("""{"a":1} x""")
    }

    @Test
    fun stringifySupportsArraysAndNestedObjects() {
        val value = listOf(
            linkedMapOf<String, Any?>("id" to "a", "ok" to true),
            linkedMapOf<String, Any?>("id" to "b", "ok" to false),
        )
        val parsed = LanJson.parse(LanJson.stringify(value)).asJsonArray()
        assertEquals(2, parsed?.size)
        assertEquals("b", parsed?.get(1).asJsonObject()?.stringValue("id"))
    }
}
