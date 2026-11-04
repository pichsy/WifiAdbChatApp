package dev.local.adbtype.mobile.core

import java.io.File
import java.util.UUID

/** 已配对好友（friends.json 一条记录）。 */
data class LanFriend(
    val id: String,
    var name: String,
    var host: String,
    var port: Int,
    var lastSeenMillis: Long,
    var alias: String? = null,
)

/**
 * 本机状态持久化（§8 的 Android 端等价实现）：
 *  - device_id.txt：稳定的设备唯一 ID（UUID，首次启动生成后不变）
 *  - paired.json：已配对设备 ID 数组
 *  - friends.json：已配对好友列表（id / name / host / port / lastSeen / alias）
 *  - chats/：每设备独立聊天记录（见 [ChatStore]）
 */
class LanStores(val baseDir: File) {

    val deviceIdFile: File
        get() = File(baseDir, "device_id.txt")

    val pairedFile: File
        get() = File(baseDir, "paired.json")

    val friendsFile: File
        get() = File(baseDir, "friends.json")

    val chatsDir: File
        get() = File(baseDir, "chats")

    fun ensureBaseDir(): Boolean = baseDir.exists() || baseDir.mkdirs()

    /** 读取设备 ID；没有或损坏时生成一个并持久化。 */
    fun deviceId(): String {
        ensureBaseDir()
        val existing = try {
            if (deviceIdFile.isFile) deviceIdFile.readText(Charsets.UTF_8).trim() else ""
        } catch (e: Exception) {
            ""
        }
        if (existing.isNotEmpty()) return existing
        val generated = UUID.randomUUID().toString()
        try {
            deviceIdFile.writeText(generated, Charsets.UTF_8)
        } catch (e: Exception) {
            // 写失败时本次运行仍用生成的 ID
        }
        return generated
    }

    fun loadPaired(): MutableSet<String> {
        val result = LinkedHashSet<String>()
        try {
            if (!pairedFile.isFile) return result
            val parsed = LanJson.parseOrNull(pairedFile.readText(Charsets.UTF_8)).asJsonArray() ?: return result
            for (item in parsed) {
                val id = item as? String
                if (!id.isNullOrBlank()) result.add(id)
            }
        } catch (e: Exception) {
            // 文件损坏时按空处理，不影响启动
        }
        return result
    }

    fun savePaired(ids: Set<String>) {
        ensureBaseDir()
        try {
            val json = LanJson.stringify(ids.sorted())
            writeAtomically(pairedFile, json)
        } catch (e: Exception) {
            // 忽略；下次触发时会再写
        }
    }

    fun loadFriends(): MutableList<LanFriend> {
        val result = ArrayList<LanFriend>()
        try {
            if (!friendsFile.isFile) return result
            val parsed = LanJson.parseOrNull(friendsFile.readText(Charsets.UTF_8)).asJsonArray() ?: return result
            for (item in parsed) {
                val obj = item.asJsonObject() ?: continue
                val id = obj.stringValue("id")?.takeIf { it.isNotBlank() } ?: continue
                result.add(
                    LanFriend(
                        id = id,
                        name = obj.stringValue("name") ?: "",
                        host = obj.stringValue("host") ?: "",
                        port = obj.intValue("port") ?: 0,
                        lastSeenMillis = obj.longValue("lastSeen") ?: 0L,
                        alias = obj.stringValue("alias")?.takeIf { it.isNotBlank() },
                    )
                )
            }
        } catch (e: Exception) {
            // 文件损坏时按空处理
        }
        return result
    }

    fun saveFriends(friends: Collection<LanFriend>) {
        ensureBaseDir()
        try {
            val payload = friends.map { friend ->
                val obj = LinkedHashMap<String, Any?>()
                obj["id"] = friend.id
                obj["name"] = friend.name
                obj["host"] = friend.host
                obj["port"] = friend.port
                obj["lastSeen"] = friend.lastSeenMillis
                friend.alias?.takeIf { it.isNotBlank() }?.let { obj["alias"] = it }
                obj
            }
            writeAtomically(friendsFile, LanJson.stringify(payload))
        } catch (e: Exception) {
            // 忽略；下次触发时会再写
        }
    }

    private fun writeAtomically(target: File, json: String) {
        val temp = File(target.parentFile ?: baseDir, target.name + ".tmp")
        temp.writeText(json, Charsets.UTF_8)
        if (target.exists() && !target.delete()) {
            temp.delete()
            return
        }
        if (!temp.renameTo(target)) {
            target.writeText(json, Charsets.UTF_8)
            temp.delete()
        }
    }
}
