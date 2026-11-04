package dev.local.adbtype.mobile.core

import java.io.File
import java.util.UUID

enum class ChatDirection {
    INCOMING,
    OUTGOING,
}

enum class ChatKind {
    TEXT,
    FILE,
}

/**
 * 一条聊天消息。字段与 docs/LAN-transfer-spec.md §8 对齐；
 * Android 端日期用 epoch 毫秒（电脑端用 2001 起的秒数，仅本地文件格式，不影响网络协议）。
 */
data class ChatMessage(
    val id: String = UUID.randomUUID().toString(),
    val direction: ChatDirection,
    val peerName: String,
    val dateMillis: Long = System.currentTimeMillis(),
    val kind: ChatKind,
    val text: String? = null,
    val fileName: String? = null,
    /** 文件系统绝对路径（API 28 公共 Downloads / 发送前复制到 App 私有目录的副本）。 */
    val filePath: String? = null,
    /** 公共下载目录的 content URI（API 29+ MediaStore），打开/分享优先用它。 */
    val fileUri: String? = null,
    val fileSize: Long? = null,
)

/**
 * 每设备独立聊天记录：<baseDir>/chats/<设备 ID>.json，重启后恢复。
 * 每个设备最多保留 [MAX_MESSAGES_PER_PEER] 条，清空只影响当前设备。
 */
class ChatStore(private val baseDir: File) {

    private val cache = HashMap<String, MutableList<ChatMessage>>()
    private val lock = Any()

    val chatsDir: File
        get() = File(baseDir, "chats")

    fun messagesFor(peerId: String): List<ChatMessage> = synchronized(lock) {
        loadLocked(peerId).toList()
    }

    fun append(peerId: String, message: ChatMessage): List<ChatMessage> = synchronized(lock) {
        val messages = loadLocked(peerId)
        messages.add(message)
        while (messages.size > MAX_MESSAGES_PER_PEER) {
            messages.removeAt(0)
        }
        saveLocked(peerId, messages)
        messages.toList()
    }

    /** 清空当前设备的聊天记录（不删除已收到的文件）。 */
    fun clear(peerId: String) = synchronized(lock) {
        cache[peerId] = mutableListOf()
        fileFor(peerId).delete()
        Unit
    }

    /** 预加载若干设备的会话，避免切设备时卡顿。 */
    fun preload(peerIds: Collection<String>) = synchronized(lock) {
        for (peerId in peerIds) {
            loadLocked(peerId)
        }
        Unit
    }

    fun fileFor(peerId: String): File = File(chatsDir, safePeerFileName(peerId) + ".json")

    fun messageCount(peerId: String): Int = synchronized(lock) { loadLocked(peerId).size }

    private fun loadLocked(peerId: String): MutableList<ChatMessage> {
        cache[peerId]?.let { return it }
        val loaded = readFromDisk(peerId).toMutableList()
        cache[peerId] = loaded
        return loaded
    }

    private fun readFromDisk(peerId: String): List<ChatMessage> {
        val file = fileFor(peerId)
        if (!file.isFile) return emptyList()
        val text = try {
            file.readText(Charsets.UTF_8)
        } catch (e: Exception) {
            return emptyList()
        }
        val parsed = LanJson.parseOrNull(text).asJsonArray() ?: return emptyList()
        return parsed.mapNotNull { decodeMessage(it) }
    }

    private fun decodeMessage(value: Any?): ChatMessage? {
        val obj = value.asJsonObject() ?: return null
        val direction = when (obj.stringValue("direction")) {
            "incoming" -> ChatDirection.INCOMING
            "outgoing" -> ChatDirection.OUTGOING
            else -> return null
        }
        val kind = when (obj.stringValue("kind")) {
            "text" -> ChatKind.TEXT
            "file" -> ChatKind.FILE
            else -> return null
        }
        return ChatMessage(
            id = obj.stringValue("id") ?: UUID.randomUUID().toString(),
            direction = direction,
            peerName = obj.stringValue("peerName") ?: "",
            dateMillis = obj.longValue("date") ?: 0L,
            kind = kind,
            text = obj.stringValue("text"),
            fileName = obj.stringValue("fileName"),
            filePath = obj.stringValue("filePath"),
            fileUri = obj.stringValue("fileUri"),
            fileSize = obj.longValue("fileSize"),
        )
    }

    private fun encodeMessage(message: ChatMessage): Map<String, Any?> {
        val obj = LinkedHashMap<String, Any?>()
        obj["id"] = message.id
        obj["direction"] = if (message.direction == ChatDirection.INCOMING) "incoming" else "outgoing"
        obj["peerName"] = message.peerName
        obj["date"] = message.dateMillis
        obj["kind"] = if (message.kind == ChatKind.TEXT) "text" else "file"
        message.text?.let { obj["text"] = it }
        message.fileName?.let { obj["fileName"] = it }
        message.filePath?.let { obj["filePath"] = it }
        message.fileUri?.let { obj["fileUri"] = it }
        message.fileSize?.let { obj["fileSize"] = it }
        return obj
    }

    private fun saveLocked(peerId: String, messages: List<ChatMessage>) {
        try {
            val directory = chatsDir
            if (!directory.exists() && !directory.mkdirs()) return
            val json = LanJson.stringify(messages.map { encodeMessage(it) })
            val target = fileFor(peerId)
            val temp = File(directory, target.name + ".tmp")
            temp.writeText(json, Charsets.UTF_8)
            if (target.exists() && !target.delete()) {
                temp.delete()
                return
            }
            if (!temp.renameTo(target)) {
                target.writeText(json, Charsets.UTF_8)
                temp.delete()
            }
        } catch (e: Exception) {
            // 磁盘写失败只影响持久化，不打断当前会话
        }
    }

    companion object {
        const val MAX_MESSAGES_PER_PEER = 500

        /** 设备 ID 可能来自网络，落盘前必须收敛成安全文件名。 */
        fun safePeerFileName(peerId: String): String {
            val cleaned = buildString {
                for (ch in peerId) {
                    val safe = ch.isLetterOrDigit() || ch == '-' || ch == '_' || ch == '.'
                    append(if (safe) ch else '_')
                }
            }
            val trimmed = cleaned.trim('.')
            if (trimmed.isEmpty()) return "peer"
            return trimmed.take(120)
        }
    }
}
