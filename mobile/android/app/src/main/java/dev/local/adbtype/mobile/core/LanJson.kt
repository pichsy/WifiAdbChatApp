package dev.local.adbtype.mobile.core

import java.util.Locale

class LanJsonException(message: String) : Exception(message)

/**
 * 协议用的极简 JSON 编解码器。
 *
 * 只覆盖局域网协议需要的 JSON 子集（对象 / 数组 / 字符串 / 数字 / 布尔 / null），
 * 纯 Kotlin 实现、不依赖 Android 的 org.json，所以能直接在 JVM 单元测试里验证，
 * 保证「测试里验证过的帧编解码逻辑」和 App 运行时完全一致。
 *
 * 解析结果类型：
 *  - 对象 -> LinkedHashMap<String, Any?>（保留字段顺序）
 *  - 数组 -> ArrayList<Any?>
 *  - 字符串 -> String；整数 -> Long；带小数或指数 -> Double
 *  - 布尔 -> Boolean；null -> null
 */
object LanJson {

    private const val MAX_DEPTH = 64

    /** 解析 JSON 文本；格式非法时抛 [LanJsonException]。 */
    fun parse(text: String): Any? {
        val parser = Parser(text)
        val value = parser.parseValue(0)
        parser.skipWhitespace()
        if (!parser.atEnd()) throw LanJsonException("JSON 尾部有多余内容")
        return value
    }

    /** 解析失败时返回 null，方便处理网络里收到的非法报文。 */
    fun parseOrNull(text: String?): Any? {
        if (text == null) return null
        return try {
            parse(text)
        } catch (e: Exception) {
            null
        }
    }

    /** 把 Map / List / String / Number / Boolean / null 序列化成 JSON 文本。 */
    fun stringify(value: Any?): String {
        val builder = StringBuilder()
        writeValue(value, builder)
        return builder.toString()
    }

    private fun writeValue(value: Any?, out: StringBuilder) {
        when (value) {
            null -> out.append("null")
            is String -> writeString(value, out)
            is Boolean -> out.append(if (value) "true" else "false")
            is Long, is Int, is Short, is Byte -> out.append(value.toString())
            is Double -> {
                if (value.isNaN() || value.isInfinite()) throw LanJsonException("非法数字")
                out.append(value.toString())
            }
            is Float -> {
                if (value.isNaN() || value.isInfinite()) throw LanJsonException("非法数字")
                out.append(value.toString())
            }
            is Number -> out.append(value.toString())
            is Map<*, *> -> {
                out.append('{')
                var first = true
                for ((key, item) in value) {
                    if (!first) out.append(',')
                    first = false
                    writeString(key?.toString() ?: "", out)
                    out.append(':')
                    writeValue(item, out)
                }
                out.append('}')
            }
            is Iterable<*> -> {
                out.append('[')
                var first = true
                for (item in value) {
                    if (!first) out.append(',')
                    first = false
                    writeValue(item, out)
                }
                out.append(']')
            }
            is Array<*> -> {
                out.append('[')
                var first = true
                for (item in value) {
                    if (!first) out.append(',')
                    first = false
                    writeValue(item, out)
                }
                out.append(']')
            }
            else -> throw LanJsonException("不支持的 JSON 类型：" + value.javaClass.name)
        }
    }

    private fun writeString(value: String, out: StringBuilder) {
        out.append('"')
        for (ch in value) {
            when (ch) {
                '"' -> out.append("\\\"")
                '\\' -> out.append("\\\\")
                '\n' -> out.append("\\n")
                '\r' -> out.append("\\r")
                '\t' -> out.append("\\t")
                '\b' -> out.append("\\b")
                '\u000C' -> out.append("\\f")
                else -> if (ch < ' ') {
                    out.append(String.format(Locale.ROOT, "\\u%04x", ch.code))
                } else {
                    out.append(ch)
                }
            }
        }
        out.append('"')
    }

    private class Parser(private val source: String) {
        private var position = 0

        fun atEnd(): Boolean = position >= source.length

        fun skipWhitespace() {
            while (position < source.length && source[position].isWhitespace()) position++
        }

        fun parseValue(depth: Int): Any? {
            if (depth > MAX_DEPTH) throw LanJsonException("JSON 嵌套过深")
            skipWhitespace()
            if (atEnd()) throw LanJsonException("JSON 意外结束")
            return when (val ch = source[position]) {
                '{' -> parseObject(depth)
                '[' -> parseArray(depth)
                '"' -> parseString()
                't' -> parseKeyword("true", true)
                'f' -> parseKeyword("false", false)
                'n' -> parseKeyword("null", null)
                else -> if (ch == '-' || ch in '0'..'9') {
                    parseNumber()
                } else {
                    throw LanJsonException("非法字符：$ch")
                }
            }
        }

        private fun parseObject(depth: Int): Map<String, Any?> {
            expect('{')
            val result = LinkedHashMap<String, Any?>()
            skipWhitespace()
            if (peek() == '}') {
                position++
                return result
            }
            while (true) {
                skipWhitespace()
                if (peek() != '"') throw LanJsonException("对象的键必须是字符串")
                val key = parseString()
                skipWhitespace()
                expect(':')
                result[key] = parseValue(depth + 1)
                skipWhitespace()
                when (peek()) {
                    ',' -> position++
                    '}' -> {
                        position++
                        return result
                    }
                    else -> throw LanJsonException("对象末尾缺少 }")
                }
            }
        }

        private fun parseArray(depth: Int): List<Any?> {
            expect('[')
            val result = ArrayList<Any?>()
            skipWhitespace()
            if (peek() == ']') {
                position++
                return result
            }
            while (true) {
                result.add(parseValue(depth + 1))
                skipWhitespace()
                when (peek()) {
                    ',' -> position++
                    ']' -> {
                        position++
                        return result
                    }
                    else -> throw LanJsonException("数组末尾缺少 ]")
                }
            }
        }

        private fun parseString(): String {
            expect('"')
            val builder = StringBuilder()
            while (true) {
                if (atEnd()) throw LanJsonException("字符串没有结束")
                val ch = source[position++]
                when (ch) {
                    '"' -> return builder.toString()
                    '\\' -> {
                        if (atEnd()) throw LanJsonException("转义字符没有结束")
                        when (val escape = source[position++]) {
                            '"' -> builder.append('"')
                            '\\' -> builder.append('\\')
                            '/' -> builder.append('/')
                            'b' -> builder.append('\b')
                            'f' -> builder.append('\u000C')
                            'n' -> builder.append('\n')
                            'r' -> builder.append('\r')
                            't' -> builder.append('\t')
                            'u' -> {
                                if (position + 4 > source.length) throw LanJsonException("\\u 转义不完整")
                                val hex = source.substring(position, position + 4)
                                position += 4
                                val code = hex.toIntOrNull(16) ?: throw LanJsonException("\\u 转义非法")
                                builder.append(code.toChar())
                            }
                            else -> throw LanJsonException("未知转义字符：\\$escape")
                        }
                    }
                    else -> builder.append(ch)
                }
            }
        }

        private fun parseNumber(): Any {
            val start = position
            if (peek() == '-') position++
            while (!atEnd() && source[position].isAsciiDigit()) position++
            var isDouble = false
            if (!atEnd() && source[position] == '.') {
                isDouble = true
                position++
                while (!atEnd() && source[position].isAsciiDigit()) position++
            }
            if (!atEnd() && (source[position] == 'e' || source[position] == 'E')) {
                isDouble = true
                position++
                if (!atEnd() && (source[position] == '+' || source[position] == '-')) position++
                while (!atEnd() && source[position].isAsciiDigit()) position++
            }
            val raw = source.substring(start, position)
            if (raw.isEmpty() || raw == "-") throw LanJsonException("数字格式非法")
            return if (isDouble) {
                raw.toDoubleOrNull() ?: throw LanJsonException("数字格式非法")
            } else {
                raw.toLongOrNull() ?: raw.toDoubleOrNull() ?: throw LanJsonException("数字格式非法")
            }
        }

        private fun parseKeyword(keyword: String, value: Any?): Any? {
            if (position + keyword.length > source.length) throw LanJsonException("JSON 意外结束")
            if (source.regionMatches(position, keyword, 0, keyword.length)) {
                position += keyword.length
                return value
            }
            throw LanJsonException("非法字面量")
        }

        private fun peek(): Char = if (atEnd()) '\u0000' else source[position]

        private fun expect(ch: Char) {
            if (peek() != ch) throw LanJsonException("期望字符 $ch")
            position++
        }

        private fun Char.isAsciiDigit(): Boolean = this in '0'..'9'
    }
}

// ---- 读取解析结果的便捷扩展 ----

@Suppress("UNCHECKED_CAST")
fun Any?.asJsonObject(): Map<String, Any?>? = this as? Map<String, Any?>

@Suppress("UNCHECKED_CAST")
fun Any?.asJsonArray(): List<Any?>? = this as? List<Any?>

fun Map<String, Any?>.stringValue(key: String): String? = this[key] as? String

fun Map<String, Any?>.longValue(key: String): Long? = when (val value = this[key]) {
    is Long -> value
    is Int -> value.toLong()
    is Double -> if (value % 1.0 == 0.0) value.toLong() else null
    is String -> value.toLongOrNull()
    else -> null
}

fun Map<String, Any?>.intValue(key: String): Int? {
    val value = longValue(key) ?: return null
    if (value < Int.MIN_VALUE || value > Int.MAX_VALUE) return null
    return value.toInt()
}

fun Map<String, Any?>.booleanValue(key: String): Boolean? = this[key] as? Boolean
