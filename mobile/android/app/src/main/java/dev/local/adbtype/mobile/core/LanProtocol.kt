package dev.local.adbtype.mobile.core

/**
 * 局域网传输协议的常量与报文构造/解析，严格对齐 docs/LAN-transfer-spec.md。
 * 协议：UDP 52730 发现、TCP 4 字节大端长度 + UTF-8 JSON、6 位配对码。
 */
object LanProtocol {

    const val APP_TAG = "ADBTypeLink"
    const val VERSION = 1
    const val DISCOVERY_PORT = 52730

    /** TCP connect 超时 6 秒。 */
    const val CONNECT_TIMEOUT_MS = 6_000

    /** 已建立连接上的读写超时 30 秒。 */
    const val IO_TIMEOUT_MS = 30_000

    const val FILE_CHUNK_BYTES = 256 * 1024
    const val MAX_FRAME_BYTES = 16 * 1024 * 1024

    /** 超过 8 秒没收到广播就认为离线。 */
    const val OFFLINE_AFTER_MS = 8_000L

    /** 广播间隔 2 秒。 */
    const val ANNOUNCE_INTERVAL_MS = 2_000L

    /** 离线清理间隔 3 秒。 */
    const val PRUNE_INTERVAL_MS = 3_000L

    // 与 macOS 端保持一致的提示文案
    const val MSG_INVALID_HELLO = "协议不匹配，请升级两端应用"
    const val MSG_PROTOCOL_MISMATCH = "协议不匹配，请确认两端版本一致"
    const val MSG_NO_RESPONSE = "对方没有响应"
    const val MSG_WRONG_CODE = "配对码不对，再看一眼对方屏幕上显示的数字"
    const val MSG_FIRST_SEND = "首次给「%s」发送，需要输入对方屏幕上显示的 6 位配对码"
    const val MSG_SAVE_FAILED = "保存文件失败"

    // ---- 客户端 -> 服务端 ----

    /** hello：已配对时 code 为 null；首次配对时带上用户输入的 6 位码。 */
    fun hello(deviceId: String, deviceName: String, code: String?): Map<String, Any?> {
        val message = LinkedHashMap<String, Any?>()
        message["app"] = APP_TAG
        message["v"] = VERSION
        message["id"] = deviceId
        message["name"] = deviceName
        if (!code.isNullOrBlank()) message["code"] = code.trim()
        return message
    }

    fun text(text: String): Map<String, Any?> = linkedMapOf(
        "type" to "text",
        "text" to text,
    )

    fun file(name: String, size: Long): Map<String, Any?> = linkedMapOf(
        "type" to "file",
        "name" to name,
        "size" to size,
    )

    fun bye(): Map<String, Any?> = linkedMapOf("type" to "bye")

    // ---- 服务端 -> 客户端 ----

    fun helloOk(deviceId: String, deviceName: String): Map<String, Any?> = linkedMapOf(
        "type" to "hello_ok",
        "name" to deviceName,
        "id" to deviceId,
    )

    fun pairRequired(deviceName: String): Map<String, Any?> = linkedMapOf(
        "type" to "pair_required",
        "name" to deviceName,
    )

    fun error(message: String): Map<String, Any?> = linkedMapOf(
        "type" to "error",
        "message" to message,
    )

    fun ok(): Map<String, Any?> = linkedMapOf("type" to "ok")

    // ---- 发现报文 ----

    /** UDP 广播报文：{"app":"ADBTypeLink","v":1,"id","name","port"}；port 未就绪时返回 null。 */
    fun announcement(deviceId: String, deviceName: String, port: Int): ByteArray? {
        if (port !in 1..65535) return null
        val payload = LinkedHashMap<String, Any?>()
        payload["app"] = APP_TAG
        payload["v"] = VERSION
        payload["id"] = deviceId
        payload["name"] = deviceName
        payload["port"] = port
        return LanJson.stringify(payload).toByteArray(Charsets.UTF_8)
    }
}

/** 一条合法的发现报文（已通过校验）。 */
data class LanAnnouncement(
    val deviceId: String,
    val name: String,
    val port: Int,
    val version: Int,
)

object AnnouncementParser {

    /**
     * 校验并解析广播 payload。
     * 依据 §2.2：app/id/name/port 任一非法、id 等于本机 id 时静默丢弃（返回 null）。
     * v 不等于 1 时仍然接受（向前兼容）。
     */
    fun parse(payload: ByteArray?, selfId: String): LanAnnouncement? {
        if (payload == null || payload.isEmpty()) return null
        val decoded = LanJson.parseOrNull(String(payload, Charsets.UTF_8))?.asJsonObject() ?: return null
        if (decoded.stringValue("app") != LanProtocol.APP_TAG) return null
        val deviceId = decoded.stringValue("id")?.takeIf { it.isNotBlank() } ?: return null
        if (deviceId == selfId) return null
        val name = decoded.stringValue("name")?.takeIf { it.isNotBlank() } ?: return null
        val port = decoded.intValue("port") ?: return null
        if (port !in 1..65535) return null
        val version = decoded.intValue("v") ?: LanProtocol.VERSION
        return LanAnnouncement(deviceId, name, port, version)
    }
}
