package dev.local.adbtype.mobile.ui

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import dev.local.adbtype.mobile.PairDialogState

/** 配对弹窗：输入对方 6 位配对码；配对成功后自动重发刚才的内容。 */
@Composable
fun PairDialog(
    dialog: PairDialogState,
    onDismiss: () -> Unit,
    onSubmit: (String) -> Unit,
) {
    var code by rememberSaveable(dialog.peerId, dialog.peerName) { mutableStateOf("") }
    val clipboard = LocalClipboardManager.current
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("与「" + dialog.peerName + "」配对") },
        text = {
            Column {
                Text(
                    "首次给「" + dialog.peerName + "」发送，需要输入对方屏幕上显示的 6 位配对码。",
                    style = MaterialTheme.typography.bodyMedium,
                )
                Spacer(Modifier.height(12.dp))
                OutlinedTextField(
                    value = code,
                    onValueChange = { value -> code = value.filter { it in '0'..'9' }.take(6) },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                    label = { Text("6 位配对码") },
                    placeholder = { Text("000000") },
                    isError = dialog.error != null,
                    supportingText = {
                        Text(dialog.error ?: "对方打开 App 后，首页会显示配对码")
                    },
                    keyboardOptions = KeyboardOptions(
                        keyboardType = KeyboardType.NumberPassword,
                        imeAction = ImeAction.Done,
                    ),
                    keyboardActions = KeyboardActions(onDone = {
                        if (code.length == 6) onSubmit(code)
                    }),
                )
                TextButton(onClick = {
                    val pasted = clipboard.getText()?.text.orEmpty()
                    code = pasted.filter { it in '0'..'9' }.take(6)
                }) { Text("粘贴") }
            }
        },
        confirmButton = {
            TextButton(onClick = { onSubmit(code) }, enabled = code.length == 6) {
                Text("配对并发送")
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text("取消") }
        },
    )
}

/** 通用二次确认弹窗（清空记录 / 取消配对）。 */
@Composable
fun ConfirmDialog(
    title: String,
    message: String,
    confirmLabel: String,
    onConfirm: () -> Unit,
    onDismiss: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = { Text(message) },
        confirmButton = { TextButton(onClick = onConfirm) { Text(confirmLabel) } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("取消") } },
    )
}
