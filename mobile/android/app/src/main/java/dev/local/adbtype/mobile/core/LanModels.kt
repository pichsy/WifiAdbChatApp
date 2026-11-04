package dev.local.adbtype.mobile.core

import java.io.File

/** 一台局域网内的电脑设备（附近设备或已配对好友）。 */
data class LanPeer(
    val id: String,
    var name: String,
    var host: String,
    var port: Int,
    var lastSeenMillis: Long,
    var online: Boolean,
    var alias: String? = null,
) {
    val displayName: String
        get() = alias?.takeIf { it.isNotBlank() } ?: name
}

enum class StatusKind {
    IDLE,
    SUCCESS,
    WARNING,
    ERROR,
}

/** 对方正在等我们给出配对码（收到未配对设备的 hello）。 */
data class PairingRequest(val peerId: String, val peerName: String)

sealed class SendResult {
    object Success : SendResult()
    data class NeedsPairing(val peerName: String) : SendResult()
    data class Failure(val message: String) : SendResult()
}

/** 准备发送的文件（已复制到 App 私有目录，避免 content:// 失效）。 */
data class OutgoingFile(val file: File, val displayName: String, val size: Long)

/** 引擎状态快照：UI 每次收到 onLanChanged 后重新取一份。 */
data class LanSnapshot(
    val deviceName: String,
    val deviceId: String,
    val pairingCode: String,
    val nearby: List<LanPeer>,
    val friends: List<LanPeer>,
    val pairedIds: Set<String>,
    val conversations: Map<String, List<ChatMessage>>,
    val selectedPeerId: String?,
    val statusText: String,
    val statusKind: StatusKind,
    val busy: Boolean,
    val sendLabel: String,
    val sendProgress: Float,
    val pairingRequest: PairingRequest?,
    val discoveryError: String?,
    /** 收到的文件会保存到哪里，给用户看，例如「下载/文件互传助手」。 */
    val receiveLocationLabel: String,
)

/** 引擎事件回调（可能在任意线程触发，实现方负责切主线程）。 */
interface LanEngineListener {
    fun onLanChanged()
}
