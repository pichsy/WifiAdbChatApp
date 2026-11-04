package dev.local.adbtype.mobile.ui

import android.content.Context
import android.widget.Toast
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.AssistChip
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.local.adbtype.mobile.LanViewModel
import dev.local.adbtype.mobile.PendingFileUi
import dev.local.adbtype.mobile.UiState
import dev.local.adbtype.mobile.core.ChatDirection
import dev.local.adbtype.mobile.core.ChatKind
import dev.local.adbtype.mobile.core.ChatMessage
import com.pichs.filepicker.common.ImagePreviewDialog
import com.pichs.filepicker.common.VideoPreviewDialog
import dev.local.adbtype.mobile.core.FileNames
import dev.local.adbtype.mobile.core.LanPeer
import dev.local.adbtype.mobile.core.MediaKind
import dev.local.adbtype.mobile.core.MediaType
import dev.local.adbtype.mobile.core.PairingRequest
import dev.local.adbtype.mobile.core.StatusKind
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale

/**
 * App 根界面：未选设备时显示「设备列表」，选中设备后显示「聊天窗口」。
 * 手机上就是两级页面（列表 / 聊天），返回键回到列表。
 */
@Composable
fun LanApp(viewModel: LanViewModel) {
    val state = viewModel.state.collectAsState().value
    val selectedPeer = state.selectedPeerId?.let { id ->
        state.friends.firstOrNull { it.id == id } ?: state.nearby.firstOrNull { it.id == id }
    }
    Surface(modifier = Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
        if (selectedPeer == null) {
            DeviceListScreen(state = state, viewModel = viewModel)
        } else {
            ChatScreen(state = state, peer = selectedPeer, viewModel = viewModel)
        }
    }
    state.pairDialog?.let { dialog ->
        PairDialog(
            dialog = dialog,
            onDismiss = viewModel::dismissPairDialog,
            onSubmit = viewModel::submitPairCode,
        )
    }
}

// ==================================================================== 设备列表

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun DeviceListScreen(state: UiState, viewModel: LanViewModel) {
    Scaffold(
        modifier = Modifier.fillMaxSize(),
        containerColor = MaterialTheme.colorScheme.background,
        topBar = {
            TopAppBar(
                title = {
                    Column {
                        Text(
                            text = "文件互传助手",
                            style = MaterialTheme.typography.titleLarge,
                            fontWeight = FontWeight.SemiBold,
                        )
                        Text(
                            text = "电脑设备 · 局域网直连",
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                },
                actions = {
                    TextButton(onClick = { viewModel.reconnect() }) { Text("重新搜索") }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = MaterialTheme.colorScheme.background),
            )
        },
        bottomBar = { StatusBar(state) },
    ) { padding ->
        LazyColumn(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding),
            contentPadding = PaddingValues(start = 16.dp, end = 16.dp, top = 8.dp, bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            item(key = "self") { SelfCard(state, viewModel) }

            val discoveryError = state.discoveryError
            if (discoveryError != null) {
                item(key = "discovery-error") {
                    InfoCard(
                        title = "局域网发现不可用",
                        message = discoveryError,
                        containerColor = MaterialTheme.colorScheme.errorContainer,
                        contentColor = MaterialTheme.colorScheme.onErrorContainer,
                    )
                }
            }
            val pairingRequest = state.pairingRequest
            if (pairingRequest != null) {
                item(key = "pairing-request") {
                    PairingRequestCard(
                        request = pairingRequest,
                        pairingCode = state.pairingCode,
                        onCopy = { viewModel.copyPairingCode() },
                        onDismiss = { viewModel.dismissPairingRequest() },
                    )
                }
            }

            item(key = "friends-title") { SectionTitle("已配对", if (state.friends.isEmpty()) "" else state.friends.size.toString() + " 台") }
            if (state.friends.isEmpty()) {
                item(key = "friends-empty") {
                    HintCard("还没有已配对的电脑。附近设备出现后点「配对」，输入对方屏幕上显示的 6 位数字。")
                }
            } else {
                items(state.friends, key = { "friend-" + it.id }) { peer ->
                    DeviceRow(
                        peer = peer,
                        paired = true,
                        onClick = { viewModel.selectPeer(peer.id) },
                        onPair = null,
                    )
                }
            }

            item(key = "nearby-title") { SectionTitle("附近设备", if (state.nearby.isEmpty()) "" else state.nearby.size.toString() + " 台") }
            if (state.nearby.isEmpty()) {
                item(key = "nearby-empty") { SearchingCard() }
            } else {
                items(state.nearby, key = { "nearby-" + it.id }) { peer ->
                    DeviceRow(
                        peer = peer,
                        paired = false,
                        onClick = { viewModel.selectPeer(peer.id) },
                        onPair = { viewModel.openPairDialog(peer.id, peer.name) },
                    )
                }
            }
        }
    }
}

@Composable
private fun SelfCard(state: UiState, viewModel: LanViewModel) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(20.dp),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.primaryContainer),
    ) {
        Column(Modifier.padding(20.dp)) {
            Text(
                text = "本机",
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onPrimaryContainer.copy(alpha = 0.7f),
            )
            Spacer(Modifier.height(4.dp))
            Text(
                text = state.deviceName.ifBlank { "Android 设备" },
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onPrimaryContainer,
            )
            Spacer(Modifier.height(16.dp))
            Text(
                text = "本机配对码",
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onPrimaryContainer.copy(alpha = 0.7f),
            )
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    text = state.pairingCode.ifBlank { "------" },
                    style = MaterialTheme.typography.displaySmall.copy(
                        fontFamily = FontFamily.Monospace,
                        fontWeight = FontWeight.Bold,
                        letterSpacing = 6.sp,
                    ),
                    color = MaterialTheme.colorScheme.onPrimaryContainer,
                    modifier = Modifier.weight(1f),
                )
                TextButton(
                    onClick = { viewModel.copyPairingCode() },
                    colors = ButtonDefaults.textButtonColors(contentColor = MaterialTheme.colorScheme.onPrimaryContainer),
                ) { Text("复制") }
                TextButton(
                    onClick = { viewModel.regenerateCode() },
                    colors = ButtonDefaults.textButtonColors(contentColor = MaterialTheme.colorScheme.onPrimaryContainer),
                ) { Text("换一个") }
            }
            Spacer(Modifier.height(8.dp))
            Text(
                text = "首次配对时，在电脑端的配对弹窗里输入这 6 位数字。",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onPrimaryContainer.copy(alpha = 0.8f),
            )
            Spacer(Modifier.height(4.dp))
            Text(
                text = "收到的文件保存到：" + state.receiveLocationLabel.ifBlank { "下载/文件互传助手" },
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onPrimaryContainer.copy(alpha = 0.8f),
            )
        }
    }
}

@Composable
private fun SectionTitle(title: String, trailing: String) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(top = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            text = title,
            style = MaterialTheme.typography.titleSmall,
            fontWeight = FontWeight.SemiBold,
            color = MaterialTheme.colorScheme.onSurface,
            modifier = Modifier.weight(1f),
        )
        if (trailing.isNotEmpty()) {
            Text(
                text = trailing,
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun DeviceRow(peer: LanPeer, paired: Boolean, onClick: () -> Unit, onPair: (() -> Unit)?) {
    Card(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(16.dp))
            .combinedClickable(onClick = onClick, onLongClick = onClick),
        shape = RoundedCornerShape(16.dp),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 14.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(
                modifier = Modifier
                    .size(40.dp)
                    .clip(CircleShape)
                    .background(
                        if (paired) {
                            MaterialTheme.colorScheme.primary.copy(alpha = 0.15f)
                        } else {
                            MaterialTheme.colorScheme.surfaceVariant
                        }
                    ),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    text = if (paired) "💻" else "🖥️",
                    style = MaterialTheme.typography.titleMedium,
                )
            }
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        text = peer.displayName,
                        style = MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.Medium,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                    Spacer(Modifier.width(8.dp))
                    OnlineDot(peer.online)
                }
                Spacer(Modifier.height(2.dp))
                Text(
                    text = rowSubtitle(peer, paired),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            Spacer(Modifier.width(8.dp))
            if (paired) {
                Text(
                    text = "›",
                    style = MaterialTheme.typography.headlineSmall,
                    color = MaterialTheme.colorScheme.outline,
                )
            } else {
                OutlinedButton(
                    onClick = { onPair?.invoke() },
                    shape = RoundedCornerShape(50),
                    contentPadding = PaddingValues(horizontal = 14.dp, vertical = 4.dp),
                ) { Text("配对") }
            }
        }
    }
}

@Composable
private fun OnlineDot(online: Boolean) {
    Box(
        modifier = Modifier
            .size(8.dp)
            .clip(CircleShape)
            .background(if (online) Color(0xFF22A55B) else MaterialTheme.colorScheme.outline.copy(alpha = 0.6f))
    )
}

private fun rowSubtitle(peer: LanPeer, paired: Boolean): String {
    if (!paired) return "在线 · 待配对"
    if (peer.online) return "已配对 · 在线"
    val lastSeen = formatLastSeen(peer.lastSeenMillis)
    return if (lastSeen.isNotEmpty()) "已配对 · 离线 · 上次 " + lastSeen else "已配对 · 离线"
}

@Composable
private fun HintCard(text: String) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(16.dp),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
    ) {
        Text(
            text = text,
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(16.dp),
        )
    }
}

@Composable
private fun InfoCard(title: String, message: String, containerColor: Color, contentColor: Color) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(16.dp),
        colors = CardDefaults.cardColors(containerColor = containerColor),
    ) {
        Column(Modifier.padding(16.dp)) {
            Text(title, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold, color = contentColor)
            Spacer(Modifier.height(4.dp))
            Text(message, style = MaterialTheme.typography.bodySmall, color = contentColor)
        }
    }
}

@Composable
private fun PairingRequestCard(
    request: PairingRequest,
    pairingCode: String,
    onCopy: () -> Unit,
    onDismiss: () -> Unit,
) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(16.dp),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.secondaryContainer),
    ) {
        Column(Modifier.padding(16.dp)) {
            Text(
                text = "配对请求",
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSecondaryContainer,
            )
            Spacer(Modifier.height(4.dp))
            Text(
                text = "「" + request.peerName + "」正在请求配对，把本机配对码 " + pairingCode + " 告诉对方。",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSecondaryContainer,
            )
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                TextButton(onClick = onCopy) { Text("复制配对码") }
                TextButton(onClick = onDismiss) { Text("知道了") }
            }
        }
    }
}

@Composable
private fun SearchingCard() {
    Card(
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(16.dp),
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surface),
    ) {
        Column(Modifier.padding(16.dp)) {
            Text(
                text = "正在搜索局域网内的电脑…",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurface,
            )
            Spacer(Modifier.height(8.dp))
            LinearProgressIndicator(modifier = Modifier.fillMaxWidth())
            Spacer(Modifier.height(8.dp))
            Text(
                text = "请确认两台设备连接同一个 Wi-Fi / 局域网，并且电脑端「文件互传助手」已打开。",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
private fun StatusBar(state: UiState) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(MaterialTheme.colorScheme.surface)
            .navigationBarsPadding()
            .padding(horizontal = 16.dp, vertical = 10.dp),
    ) {
        if (state.busy) {
            LinearProgressIndicator(progress = { state.sendProgress }, modifier = Modifier.fillMaxWidth())
            Spacer(Modifier.height(6.dp))
        }
        Text(
            text = state.statusText,
            style = MaterialTheme.typography.bodySmall,
            color = statusColor(state.statusKind),
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

@Composable
private fun statusColor(kind: StatusKind): Color = when (kind) {
    StatusKind.SUCCESS -> Color(0xFF1B7F3B)
    StatusKind.WARNING -> Color(0xFF9A6700)
    StatusKind.ERROR -> MaterialTheme.colorScheme.error
    StatusKind.IDLE -> MaterialTheme.colorScheme.onSurfaceVariant
}

// ==================================================================== 聊天窗口

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ChatScreen(state: UiState, peer: LanPeer, viewModel: LanViewModel) {
    var menuOpen by remember { mutableStateOf(false) }
    var showClearDialog by remember { mutableStateOf(false) }
    var showUnpairDialog by remember { mutableStateOf(false) }
    val filePicker = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { uris ->
        viewModel.addPickedFiles(uris)
    }
    BackHandler { viewModel.selectPeer(null) }

    Scaffold(
        modifier = Modifier.fillMaxSize(),
        containerColor = MaterialTheme.colorScheme.background,
        topBar = {
            TopAppBar(
                navigationIcon = {
                    TextButton(onClick = { viewModel.selectPeer(null) }) {
                        Text("‹", fontSize = 26.sp, color = MaterialTheme.colorScheme.onSurface)
                    }
                },
                title = {
                    Column {
                        Text(
                            text = peer.displayName,
                            style = MaterialTheme.typography.titleMedium,
                            fontWeight = FontWeight.SemiBold,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                        Text(
                            text = headerSubtitle(state, peer),
                            style = MaterialTheme.typography.labelSmall,
                            color = if (peer.online) Color(0xFF22A55B) else MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                },
                actions = {
                    Box {
                        IconButton(onClick = { menuOpen = true }) {
                            Text("⋮", fontSize = 22.sp, color = MaterialTheme.colorScheme.onSurface)
                        }
                        DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                            DropdownMenuItem(
                                text = { Text("清空聊天记录") },
                                onClick = {
                                    menuOpen = false
                                    showClearDialog = true
                                },
                            )
                            if (state.pairedIds.contains(peer.id)) {
                                DropdownMenuItem(
                                    text = { Text("取消配对") },
                                    onClick = {
                                        menuOpen = false
                                        showUnpairDialog = true
                                    },
                                )
                            }
                            DropdownMenuItem(
                                text = { Text("重新搜索设备") },
                                onClick = {
                                    menuOpen = false
                                    viewModel.reconnect()
                                },
                            )
                        }
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = MaterialTheme.colorScheme.surface),
            )
        },
        bottomBar = {
            Composer(state = state, viewModel = viewModel, onPickFiles = { filePicker.launch(arrayOf("*/*")) })
        },
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding),
        ) {
            if (!state.pairedIds.contains(peer.id)) {
                PairingHintBar(onPair = { viewModel.openPairDialog(peer.id, peer.name) })
            }
            val request = state.pairingRequest
            if (request != null && request.peerId == peer.id) {
                InlinePairingRequest(request = request, pairingCode = state.pairingCode, viewModel = viewModel)
            }
            Box(Modifier.weight(1f)) {
                if (state.messages.isEmpty()) {
                    EmptyChat()
                } else {
                    MessageList(state = state, viewModel = viewModel)
                }
            }
        }
    }

    if (showClearDialog) {
        ConfirmDialog(
            title = "清空聊天记录",
            message = "只会清除「" + peer.displayName + "」的聊天记录，已收到的文件不会被删除。",
            confirmLabel = "清空",
            onConfirm = {
                showClearDialog = false
                viewModel.clearConversation()
            },
            onDismiss = { showClearDialog = false },
        )
    }
    if (showUnpairDialog) {
        ConfirmDialog(
            title = "取消配对",
            message = "取消后再次发送需要重新输入对方的配对码，聊天记录会保留。",
            confirmLabel = "取消配对",
            onConfirm = {
                showUnpairDialog = false
                viewModel.unpair(peer.id)
                viewModel.selectPeer(null)
            },
            onDismiss = { showUnpairDialog = false },
        )
    }
}

private fun headerSubtitle(state: UiState, peer: LanPeer): String {
    if (!state.pairedIds.contains(peer.id)) return "未配对 · 首次发送需要输入对方的 6 位配对码"
    if (peer.online) return "已配对 · 在线"
    val lastSeen = formatLastSeen(peer.lastSeenMillis)
    return if (lastSeen.isNotEmpty()) "已配对 · 离线 · 上次 " + lastSeen else "已配对 · 离线"
}

@Composable
private fun PairingHintBar(onPair: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(MaterialTheme.colorScheme.secondaryContainer)
            .padding(horizontal = 16.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            text = "未配对：首次发送需要输入对方屏幕上显示的 6 位配对码",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSecondaryContainer,
            modifier = Modifier.weight(1f),
        )
        TextButton(onClick = onPair) { Text("立即配对") }
    }
}

@Composable
private fun InlinePairingRequest(request: PairingRequest, pairingCode: String, viewModel: LanViewModel) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(MaterialTheme.colorScheme.primaryContainer)
            .padding(horizontal = 16.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            text = "「" + request.peerName + "」正在请求配对，把本机配对码 " + pairingCode + " 告诉对方",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onPrimaryContainer,
            modifier = Modifier.weight(1f),
        )
        TextButton(onClick = { viewModel.copyPairingCode() }) { Text("复制") }
        TextButton(onClick = { viewModel.dismissPairingRequest() }) { Text("知道了") }
    }
}

@Composable
private fun EmptyChat() {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Text("👋", style = MaterialTheme.typography.displaySmall)
        Spacer(Modifier.height(12.dp))
        Text("还没有消息", style = MaterialTheme.typography.titleMedium)
        Spacer(Modifier.height(6.dp))
        Text(
            text = "收到的文字和文件会像聊天一样显示在这里，发出去的内容也会留在上面。",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
        )
    }
}

@Composable
private fun MessageList(state: UiState, viewModel: LanViewModel) {
    val listState = rememberLazyListState()
    LaunchedEffect(state.messages.size) {
        if (state.messages.isNotEmpty()) {
            listState.animateScrollToItem(state.messages.size - 1)
        }
    }
    LazyColumn(
        state = listState,
        modifier = Modifier.fillMaxSize(),
        contentPadding = PaddingValues(horizontal = 12.dp, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        items(state.messages, key = { it.id }) { message ->
            MessageBubble(
                message = message,
                savedLocationLabel = state.receiveLocationLabel,
                onCopyText = { viewModel.copyText(it) },
            )
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun MessageBubble(
    message: ChatMessage,
    savedLocationLabel: String,
    onCopyText: (String) -> Unit,
) {
    val incoming = message.direction == ChatDirection.INCOMING
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = if (incoming) Arrangement.Start else Arrangement.End,
    ) {
        Column(
            horizontalAlignment = if (incoming) Alignment.Start else Alignment.End,
            modifier = Modifier.widthIn(max = 300.dp),
        ) {
            if (incoming) {
                Text(
                    text = message.peerName.ifBlank { "对方" },
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Spacer(Modifier.height(2.dp))
            }
            if (message.kind == ChatKind.TEXT) {
                val text = message.text.orEmpty()
                Box(
                    modifier = Modifier
                        .clip(RoundedCornerShape(16.dp))
                        .background(
                            if (incoming) {
                                MaterialTheme.colorScheme.surfaceVariant
                            } else {
                                MaterialTheme.colorScheme.primary
                            }
                        )
                        .combinedClickable(onClick = {}, onLongClick = { onCopyText(text) })
                        .padding(horizontal = 14.dp, vertical = 10.dp),
                ) {
                    Text(
                        text = text,
                        style = MaterialTheme.typography.bodyLarge,
                        color = if (incoming) MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.onPrimary,
                    )
                }
            } else {
                FileBubble(message = message, incoming = incoming, savedLocationLabel = savedLocationLabel)
            }
            Spacer(Modifier.height(2.dp))
            Text(
                text = formatTime(message.dateMillis),
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.8f),
            )
        }
    }
}

@Composable
private fun FileBubble(message: ChatMessage, incoming: Boolean, savedLocationLabel: String) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val exists = remember(message.id, message.fileUri, message.filePath) {
        FileActions.exists(context, message)
    }
    val kind = remember(message.fileName) { MediaType.of(message.fileName) }
    val isMedia = exists && kind != MediaKind.OTHER
    Column(
        modifier = Modifier
            .clip(RoundedCornerShape(16.dp))
            .background(
                if (incoming) {
                    MaterialTheme.colorScheme.surfaceVariant
                } else {
                    MaterialTheme.colorScheme.primaryContainer
                }
            )
            .padding(12.dp),
    ) {
        if (isMedia) {
            Box(
                modifier = Modifier
                    .clip(RoundedCornerShape(12.dp))
                    .clickable { openMediaPreview(context, scope, message, kind) },
            ) {
                MediaThumbnail(message = message, kind = kind)
            }
            Spacer(Modifier.height(6.dp))
            Text(
                text = message.fileName ?: "文件",
                style = MaterialTheme.typography.bodyMedium,
                color = if (incoming) {
                    MaterialTheme.colorScheme.onSurface
                } else {
                    MaterialTheme.colorScheme.onPrimaryContainer
                },
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.widthIn(max = 220.dp),
            )
            Text(
                text = buildString {
                    append(FileNames.formatSize(message.fileSize ?: -1L))
                    append(" · ")
                    append(
                        if (incoming) {
                            "已保存到 " + savedLocationLabel.ifBlank { "下载/文件互传助手" }
                        } else {
                            "已发送"
                        }
                    )
                },
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Spacer(Modifier.height(4.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                TextButton(onClick = { openMediaPreview(context, scope, message, kind) }) {
                    Text(if (kind == MediaKind.VIDEO) "播放" else "查看大图")
                }
                TextButton(onClick = { FileActions.shareFile(context, message) }) {
                    Text("分享")
                }
            }
        } else {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("📄", style = MaterialTheme.typography.titleLarge)
                Spacer(Modifier.width(8.dp))
                Column(Modifier.weight(1f, fill = false)) {
                    Text(
                        text = message.fileName ?: "文件",
                        style = MaterialTheme.typography.bodyMedium,
                        color = if (incoming) {
                            MaterialTheme.colorScheme.onSurface
                        } else {
                            MaterialTheme.colorScheme.onPrimaryContainer
                        },
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                        textDecoration = if (exists) null else TextDecoration.LineThrough,
                    )
                    Text(
                        text = buildString {
                            append(FileNames.formatSize(message.fileSize ?: -1L))
                            append(" · ")
                            append(
                                when {
                                    !exists -> "文件已不存在"
                                    incoming -> "已保存到 " + savedLocationLabel.ifBlank { "下载/文件互传助手" }
                                    else -> "已发送"
                                }
                            )
                        },
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
            if (exists) {
                Spacer(Modifier.height(6.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                    TextButton(onClick = { FileActions.openFile(context, message) }) {
                        Text("打开")
                    }
                    TextButton(onClick = { FileActions.shareFile(context, message) }) {
                        Text("分享")
                    }
                }
            }
        }
    }
}

/** 点击图片/视频：先准备本地路径，再交给 filepicker 的全屏预览弹窗。 */
private fun openMediaPreview(
    context: Context,
    scope: CoroutineScope,
    message: ChatMessage,
    kind: MediaKind,
) {
    scope.launch {
        val localPath = MediaPreview.localMediaPath(context, message)
        if (localPath == null) {
            Toast.makeText(context, "文件已不存在，可能被删除了", Toast.LENGTH_SHORT).show()
            return@launch
        }
        try {
            when (kind) {
                MediaKind.IMAGE -> ImagePreviewDialog(context, localPath, title = message.fileName).showPopupWindow()
                MediaKind.VIDEO -> VideoPreviewDialog(context, localPath, title = message.fileName).showPopupWindow()
                MediaKind.OTHER -> Unit
            }
        } catch (error: Throwable) {
            Toast.makeText(context, "预览失败：" + (error.message ?: "未知错误"), Toast.LENGTH_SHORT).show()
        }
    }
}

@Composable
private fun Composer(state: UiState, viewModel: LanViewModel, onPickFiles: () -> Unit) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(MaterialTheme.colorScheme.surface)
            .imePadding()
            .navigationBarsPadding(),
    ) {
        if (state.busy) {
            Column(
                Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 6.dp),
            ) {
                LinearProgressIndicator(progress = { state.sendProgress }, modifier = Modifier.fillMaxWidth())
                Spacer(Modifier.height(4.dp))
                Text(
                    text = if (state.sendLabel.isBlank()) "正在发送…" else "正在发送 " + state.sendLabel,
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
        if (state.pendingFiles.isNotEmpty()) {
            LazyRow(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 12.dp, vertical = 6.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                items(state.pendingFiles, key = { it.file.absolutePath }) { pending ->
                    PendingFileChip(pending = pending, onRemove = { viewModel.removePendingFile(pending) })
                }
            }
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    text = "待发送 " + state.pendingFiles.size + " 个文件",
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.weight(1f),
                )
                TextButton(onClick = { viewModel.clearPendingFiles() }) { Text("清空") }
                Spacer(Modifier.width(4.dp))
                Button(onClick = { viewModel.sendPendingFiles() }, enabled = !state.busy) {
                    Text("发送文件")
                }
            }
        }
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(start = 8.dp, end = 12.dp, top = 6.dp, bottom = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            IconButton(onClick = onPickFiles) {
                Text("📎", fontSize = 22.sp)
            }
            OutlinedTextField(
                value = state.input,
                onValueChange = viewModel::updateInput,
                modifier = Modifier.weight(1f),
                placeholder = { Text("发消息…") },
                maxLines = 4,
                shape = RoundedCornerShape(24.dp),
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Send),
                keyboardActions = KeyboardActions(onSend = { viewModel.sendText() }),
            )
            Spacer(Modifier.width(8.dp))
            Button(
                onClick = { viewModel.sendText() },
                enabled = !state.busy && state.input.isNotBlank(),
                shape = RoundedCornerShape(50),
                contentPadding = PaddingValues(horizontal = 20.dp, vertical = 12.dp),
            ) { Text("发送") }
        }
    }
}

@Composable
private fun PendingFileChip(pending: PendingFileUi, onRemove: () -> Unit) {
    AssistChip(
        onClick = onRemove,
        label = {
            Text(
                text = pending.displayName,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.widthIn(max = 150.dp),
            )
        },
        trailingIcon = { Text("✕", style = MaterialTheme.typography.labelSmall) },
    )
}

// ==================================================================== 工具

private fun formatTime(millis: Long): String {
    if (millis <= 0L) return ""
    return SimpleDateFormat("HH:mm", Locale.getDefault()).format(Date(millis))
}

private fun formatLastSeen(millis: Long): String {
    if (millis <= 0L) return ""
    val now = Calendar.getInstance()
    val then = Calendar.getInstance().apply { timeInMillis = millis }
    val sameDay = now.get(Calendar.YEAR) == then.get(Calendar.YEAR) &&
        now.get(Calendar.DAY_OF_YEAR) == then.get(Calendar.DAY_OF_YEAR)
    val pattern = if (sameDay) "HH:mm" else "MM-dd HH:mm"
    return SimpleDateFormat(pattern, Locale.getDefault()).format(Date(millis))
}
