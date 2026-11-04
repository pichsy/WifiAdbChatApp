package dev.local.adbtype.mobile

import android.app.Application
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import dev.local.adbtype.mobile.core.ChatMessage
import dev.local.adbtype.mobile.core.FileNames
import dev.local.adbtype.mobile.core.LanEngine
import dev.local.adbtype.mobile.core.LanEngineListener
import dev.local.adbtype.mobile.core.LanPeer
import dev.local.adbtype.mobile.core.LanProtocol
import dev.local.adbtype.mobile.core.LanStores
import dev.local.adbtype.mobile.core.OutgoingFile
import dev.local.adbtype.mobile.core.PairingRequest
import dev.local.adbtype.mobile.core.SendResult
import dev.local.adbtype.mobile.core.StatusKind
import dev.local.adbtype.mobile.data.AndroidReceivedFilePublisher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

/** 配对弹窗状态：pending 表示「配对后要继续发送的内容」。 */
data class PairDialogState(
    val peerId: String,
    val peerName: String,
    val error: String? = null,
)

/** 待发送文件（已复制到 App 私有目录）。 */
data class PendingFileUi(val file: File, val displayName: String, val size: Long)

data class UiState(
    val deviceName: String = "",
    val deviceId: String = "",
    val pairingCode: String = "",
    val nearby: List<LanPeer> = emptyList(),
    val friends: List<LanPeer> = emptyList(),
    val pairedIds: Set<String> = emptySet(),
    val selectedPeerId: String? = null,
    val messages: List<ChatMessage> = emptyList(),
    val statusText: String = "正在启动局域网发现…",
    val statusKind: StatusKind = StatusKind.IDLE,
    val busy: Boolean = false,
    val sendLabel: String = "",
    val sendProgress: Float = 0f,
    val pairingRequest: PairingRequest? = null,
    val discoveryError: String? = null,
    /** 收到的文件保存位置，给用户看，例如「下载/文件互传助手」。 */
    val receiveLocationLabel: String = "",
    val input: String = "",
    val pendingFiles: List<PendingFileUi> = emptyList(),
    val pairDialog: PairDialogState? = null,
)

/**
 * 把 [LanEngine] 的网络状态映射成 Compose 界面状态，并处理配对弹窗、
 * 文件选择 / 复制到私有目录等 Android 特有的交互。
 */
class LanViewModel(application: Application) : AndroidViewModel(application), LanEngineListener {

    private val app = application
    private val mainHandler = Handler(Looper.getMainLooper())
    private val stores = LanStores(File(application.filesDir, "lan"))
    private val receivedFilePublisher = AndroidReceivedFilePublisher(application.applicationContext)
    private val engine = LanEngine(
        stores = stores,
        receivedFilePublisher = receivedFilePublisher,
        deviceNameProvider = { defaultDeviceName() },
        listener = this,
    )

    private val _state = MutableStateFlow(UiState())
    val state: StateFlow<UiState> = _state.asStateFlow()

    private val pendingFiles = mutableListOf<PendingFileUi>()
    private var pairDialog: PairDialogState? = null
    private var pendingSend: PendingSend? = null
    private var multicastLock: WifiManager.MulticastLock? = null

    private sealed interface PendingSend {
        data class Text(val text: String) : PendingSend
        data class Files(val files: List<PendingFileUi>) : PendingSend
    }

    init {
        multicastLock = acquireMulticastLock()
        viewModelScope.launch(Dispatchers.IO) { engine.start() }
        refresh()
    }

    override fun onCleared() {
        try {
            engine.stop()
        } catch (e: Exception) {
            // 退出时忽略网络关闭异常
        }
        releaseMulticastLock()
        super.onCleared()
    }

    override fun onLanChanged() {
        mainHandler.post { refresh() }
    }

    // ------------------------------------------------------------ 界面操作

    fun selectPeer(peerId: String?) {
        engine.selectPeer(peerId)
        refresh()
    }

    fun updateInput(value: String) {
        _state.value = _state.value.copy(input = value)
    }

    fun setStatusMessage(text: String, kind: StatusKind) {
        engine.setStatusMessage(text, kind)
    }

    fun reconnect() {
        engine.restartDiscovery()
    }

    fun regenerateCode() {
        engine.regeneratePairingCode()
    }

    fun copyPairingCode() {
        val code = _state.value.pairingCode
        if (code.isBlank()) return
        val clipboard = app.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager ?: return
        clipboard.setPrimaryClip(ClipData.newPlainText("配对码", code))
        engine.setStatusMessage("已复制本机配对码 " + code, StatusKind.SUCCESS)
    }

    fun copyText(text: String) {
        if (text.isBlank()) return
        val clipboard = app.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager ?: return
        clipboard.setPrimaryClip(ClipData.newPlainText("聊天文字", text))
        engine.setStatusMessage("已复制文字", StatusKind.SUCCESS)
    }

    fun dismissPairingRequest() {
        engine.dismissPairingRequest()
    }

    fun clearConversation() {
        val peerId = _state.value.selectedPeerId ?: return
        engine.clearConversation(peerId)
        refresh()
    }

    fun unpair(peerId: String) {
        engine.unpair(peerId)
        refresh()
    }

    // ------------------------------------------------------------ 配对

    fun openPairDialog(peerId: String, peerName: String) {
        pendingSend = null
        pairDialog = PairDialogState(peerId = peerId, peerName = peerName)
        refresh()
    }

    fun dismissPairDialog() {
        pendingSend = null
        pairDialog = null
        refresh()
    }

    fun submitPairCode(codeInput: String) {
        val dialog = pairDialog ?: return
        val digits = codeInput.filter { it in '0'..'9' }
        if (digits.length != 6) {
            pairDialog = dialog.copy(error = "配对码是 6 位数字")
            refresh()
            return
        }
        pairDialog = dialog.copy(error = null)
        refresh()
        val pending = pendingSend
        if (pending == null) {
            engine.pairWith(dialog.peerId, digits) { result ->
                mainHandler.post { handlePairOnlyResult(result, dialog.peerId) }
            }
            return
        }
        when (pending) {
            is PendingSend.Text -> engine.sendText(dialog.peerId, pending.text, digits) { result ->
                mainHandler.post { handlePairRetryResult(result, dialog.peerId) }
            }
            is PendingSend.Files -> engine.sendFiles(
                dialog.peerId,
                pending.files.map { OutgoingFile(it.file, it.displayName, it.size) },
                digits,
            ) { result ->
                mainHandler.post { handlePairRetryResult(result, dialog.peerId) }
            }
        }
    }

    private fun handlePairOnlyResult(result: SendResult, peerId: String) {
        when (result) {
            is SendResult.Success -> {
                pairDialog = null
                pendingSend = null
                engine.selectPeer(peerId)
                engine.setStatusMessage("配对成功，可以直接发送文字和文件", StatusKind.SUCCESS)
                refresh()
            }
            is SendResult.NeedsPairing -> {
                pairDialog = pairDialog?.copy(error = LanProtocol.MSG_WRONG_CODE)
                refresh()
            }
            is SendResult.Failure -> {
                pairDialog = pairDialog?.copy(error = result.message)
                refresh()
            }
        }
    }

    private fun handlePairRetryResult(result: SendResult, peerId: String) {
        when (result) {
            is SendResult.Success -> {
                pairDialog = null
                pendingSend = null
                pendingFiles.clear()
                engine.selectPeer(peerId)
                refresh()
            }
            is SendResult.NeedsPairing -> {
                pairDialog = pairDialog?.copy(error = LanProtocol.MSG_WRONG_CODE)
                refresh()
            }
            is SendResult.Failure -> {
                pairDialog = pairDialog?.copy(error = result.message)
                refresh()
            }
        }
    }

    private fun handleSendResult(result: SendResult, pending: PendingSend, peerId: String) {
        when (result) {
            is SendResult.Success -> {
                pendingSend = null
                pairDialog = null
                if (pending is PendingSend.Files) pendingFiles.clear()
                engine.selectPeer(peerId)
                refresh()
            }
            is SendResult.NeedsPairing -> {
                pendingSend = pending
                pairDialog = PairDialogState(peerId = peerId, peerName = result.peerName)
                refresh()
            }
            is SendResult.Failure -> {
                pendingSend = null
                engine.setStatusMessage(result.message, StatusKind.ERROR)
                if (pending is PendingSend.Text && _state.value.input.isBlank()) {
                    _state.value = _state.value.copy(input = pending.text)
                }
                refresh()
            }
        }
    }

    // ------------------------------------------------------------ 发送

    fun sendText() {
        val current = _state.value
        val peerId = current.selectedPeerId
        if (peerId == null) {
            engine.setStatusMessage("先在列表里选择设备", StatusKind.WARNING)
            return
        }
        if (current.busy) return
        val text = current.input
        if (text.trim().isEmpty()) {
            engine.setStatusMessage("先输入要发送的文字", StatusKind.WARNING)
            return
        }
        _state.value = current.copy(input = "")
        val pending = PendingSend.Text(text)
        engine.sendText(peerId, text, null) { result ->
            mainHandler.post { handleSendResult(result, pending, peerId) }
        }
    }

    fun sendPendingFiles() {
        val current = _state.value
        val peerId = current.selectedPeerId
        if (peerId == null) {
            engine.setStatusMessage("先在列表里选择设备", StatusKind.WARNING)
            return
        }
        if (current.busy) return
        if (pendingFiles.isEmpty()) {
            engine.setStatusMessage("先选择文件", StatusKind.WARNING)
            return
        }
        val files = pendingFiles.toList()
        val pending = PendingSend.Files(files)
        engine.sendFiles(peerId, files.map { OutgoingFile(it.file, it.displayName, it.size) }, null) { result ->
            mainHandler.post { handleSendResult(result, pending, peerId) }
        }
    }

    fun addPickedFiles(uris: List<Uri>) {
        if (uris.isEmpty()) return
        viewModelScope.launch {
            val added = withContext(Dispatchers.IO) { uris.mapNotNull { copyToOutgoing(it) } }
            if (added.isEmpty()) {
                engine.setStatusMessage("没有读到选中的文件", StatusKind.ERROR)
            } else {
                pendingFiles.addAll(added)
                engine.setStatusMessage("已选择 " + added.size + " 个文件，点「发送文件」发给对方", StatusKind.IDLE)
            }
            refresh()
        }
    }

    fun removePendingFile(pending: PendingFileUi) {
        pendingFiles.remove(pending)
        refresh()
    }

    fun clearPendingFiles() {
        pendingFiles.clear()
        refresh()
    }

    private fun copyToOutgoing(uri: Uri): PendingFileUi? {
        return try {
            val resolver = app.contentResolver
            var displayName = "file"
            resolver.query(uri, null, null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (nameIndex >= 0) {
                        val value = cursor.getString(nameIndex)
                        if (!value.isNullOrBlank()) displayName = value
                    }
                }
            }
            val safeName = FileNames.sanitizeIncoming(displayName) ?: "file"
            val directory = outgoingDirectory()
            if (!directory.exists() && !directory.mkdirs()) return null
            val target = FileNames.uniqueFile(directory, safeName)
            resolver.openInputStream(uri)?.use { input ->
                target.outputStream().use { output -> input.copyTo(output) }
            } ?: return null
            val size = target.length()
            if (size <= 0L) {
                target.delete()
                return null
            }
            PendingFileUi(target, target.name, size)
        } catch (e: Exception) {
            null
        }
    }

    // ------------------------------------------------------------ 内部

    private fun refresh() {
        val snapshot = engine.snapshot()
        val selected = snapshot.selectedPeerId
        val messages = if (selected != null) snapshot.conversations[selected] ?: emptyList() else emptyList()
        _state.value = _state.value.copy(
            deviceName = snapshot.deviceName,
            deviceId = snapshot.deviceId,
            pairingCode = snapshot.pairingCode,
            nearby = snapshot.nearby,
            friends = snapshot.friends,
            pairedIds = snapshot.pairedIds,
            selectedPeerId = selected,
            messages = messages,
            statusText = snapshot.statusText,
            statusKind = snapshot.statusKind,
            busy = snapshot.busy,
            sendLabel = snapshot.sendLabel,
            sendProgress = snapshot.sendProgress,
            pairingRequest = snapshot.pairingRequest,
            discoveryError = snapshot.discoveryError,
            receiveLocationLabel = snapshot.receiveLocationLabel,
            pendingFiles = pendingFiles.toList(),
            pairDialog = pairDialog,
        )
    }

    /** 存储权限变化（API 28 运行时授权）后刷新保存位置文案。 */
    fun onStoragePermissionChanged() {
        refresh()
    }

    /** 当前保存位置是否还是 App 专属目录（API 28 没有存储权限时的兜底）。 */
    fun isSavingToPrivateStorage(): Boolean =
        _state.value.receiveLocationLabel == AndroidReceivedFilePublisher.PRIVATE_LABEL

    private fun outgoingDirectory(): File = File(app.filesDir, "outgoing")

    private fun defaultDeviceName(): String {
        val manufacturer = Build.MANUFACTURER?.trim().orEmpty()
        val model = Build.MODEL?.trim().orEmpty()
        val name = when {
            model.isEmpty() -> "Android 设备"
            manufacturer.isEmpty() || model.startsWith(manufacturer, ignoreCase = true) -> model
            else -> manufacturer + " " + model
        }
        return name.take(48).ifBlank { "Android 设备" }
    }

    private fun acquireMulticastLock(): WifiManager.MulticastLock? {
        return try {
            val wifi = app.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
            val lock = wifi?.createMulticastLock("adbtype-lan") ?: return null
            lock.setReferenceCounted(false)
            lock.acquire()
            lock
        } catch (e: Exception) {
            null
        }
    }

    private fun releaseMulticastLock() {
        try {
            multicastLock?.release()
        } catch (e: Exception) {
            // 忽略
        }
        multicastLock = null
    }
}
