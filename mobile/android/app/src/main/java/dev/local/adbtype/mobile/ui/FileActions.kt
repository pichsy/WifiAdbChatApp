package dev.local.adbtype.mobile.ui

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.webkit.MimeTypeMap
import android.widget.Toast
import androidx.core.content.FileProvider
import dev.local.adbtype.mobile.core.ChatMessage
import java.io.File
import java.util.Locale

/**
 * 聊天里文件的「存在性检查 / 打开 / 分享」。
 *  - 接收文件（API 29+）：消息里存 MediaStore 的 content URI，直接用 ACTION_VIEW / ACTION_SEND；
 *  - 接收文件（API 28）：公共 Downloads 里的真实路径，经 FileProvider 转成 content URI；
 *  - 发送文件：发送前复制到 App 私有目录的副本，同样经 FileProvider。
 * 全部带 FLAG_GRANT_READ_URI_PERMISSION，接收方应用可直接读取。
 */
object FileActions {

    fun mimeType(fileName: String?): String {
        val name = fileName.orEmpty()
        val extension = name.substringAfterLast('.', "").lowercase(Locale.ROOT)
        if (extension.isEmpty()) return "application/octet-stream"
        return MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension) ?: "application/octet-stream"
    }

    /** 文件是否还在（用户可能已经在「文件管理」里删掉了）。 */
    fun exists(context: Context, message: ChatMessage): Boolean {
        val contentUri = message.fileUri?.takeIf { it.isNotBlank() }
        if (contentUri != null) {
            return try {
                context.contentResolver.openFileDescriptor(Uri.parse(contentUri), "r")?.use { true } ?: false
            } catch (e: Exception) {
                false
            }
        }
        val path = message.filePath ?: return false
        return try {
            File(path).isFile
        } catch (e: Exception) {
            false
        }
    }

    fun openFile(context: Context, message: ChatMessage) {
        val uri = uriFor(context, message)
        if (uri == null) {
            toast(context, "文件已不存在，可能被删除了")
            return
        }
        try {
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, mimeType(message.fileName))
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            context.startActivity(intent)
        } catch (e: ActivityNotFoundException) {
            toast(context, "没有可以打开该文件的应用")
        } catch (e: Exception) {
            toast(context, "打开文件失败：" + (e.message ?: "未知错误"))
        }
    }

    fun shareFile(context: Context, message: ChatMessage) {
        val uri = uriFor(context, message)
        if (uri == null) {
            toast(context, "文件已不存在，可能被删除了")
            return
        }
        try {
            val intent = Intent(Intent.ACTION_SEND).apply {
                type = mimeType(message.fileName)
                putExtra(Intent.EXTRA_STREAM, uri)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            context.startActivity(Intent.createChooser(intent, "分享文件"))
        } catch (e: ActivityNotFoundException) {
            toast(context, "没有可以分享到的应用")
        } catch (e: Exception) {
            toast(context, "分享文件失败：" + (e.message ?: "未知错误"))
        }
    }

    private fun uriFor(context: Context, message: ChatMessage): Uri? {
        val contentUri = message.fileUri?.takeIf { it.isNotBlank() }
        if (contentUri != null) {
            return try {
                Uri.parse(contentUri)
            } catch (e: Exception) {
                null
            }
        }
        val path = message.filePath ?: return null
        val file = File(path)
        if (!file.isFile) return null
        return try {
            FileProvider.getUriForFile(context, authority(context), file)
        } catch (e: Exception) {
            null
        }
    }

    private fun authority(context: Context): String = context.packageName + ".fileprovider"

    private fun toast(context: Context, message: String) {
        Toast.makeText(context, message, Toast.LENGTH_SHORT).show()
    }
}
