package dev.local.adbtype.mobile.ui

import android.content.Context
import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.util.LruCache
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.bumptech.glide.Glide
import dev.local.adbtype.mobile.core.ChatMessage
import dev.local.adbtype.mobile.core.FileNames
import dev.local.adbtype.mobile.core.MediaKind
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File

/**
 * 图片 / 视频消息的缩略图与本地预览文件准备：
 *  - 缩略图固定 120×90dp，图片用 Glide 加载（content:// 与本地路径都支持），
 *    视频用 MediaMetadataRetriever 取首帧并叠加播放图标；
 *  - 全屏预览交给 filepicker 的 ImagePreviewDialog / VideoPreviewDialog，
 *    它们只接受本地路径或 http 地址，所以 content URI 要先转成本地路径
 *    （有 filePath 直接用，否则复制到 cache/media-preview）；
 *  - 文件不存在或加载失败时显示占位、不崩溃。
 */
object MediaPreview {

    private const val CACHE_DIR = "media-preview"

    /** 得到 filepicker 弹窗能用的本地路径；拿不到返回 null（文件已不存在）。 */
    suspend fun localMediaPath(context: Context, message: ChatMessage): String? = withContext(Dispatchers.IO) {
        val filePath = message.filePath
        if (!filePath.isNullOrBlank()) {
            val file = File(filePath)
            if (file.isFile && file.length() > 0L) return@withContext filePath
        }
        val uriString = message.fileUri?.takeIf { it.isNotBlank() } ?: return@withContext null
        val uri = try {
            Uri.parse(uriString)
        } catch (e: Exception) {
            return@withContext null
        }
        val directory = File(context.cacheDir, CACHE_DIR)
        if (!directory.exists() && !directory.mkdirs()) return@withContext null
        val safeName = FileNames.sanitizeIncoming(message.fileName ?: "media") ?: "media"
        val target = File(directory, cacheFileName(message, safeName))
        val expected = message.fileSize ?: -1L
        if (target.isFile && target.length() > 0L && (expected <= 0L || target.length() == expected)) {
            return@withContext target.absolutePath
        }
        try {
            val input = context.contentResolver.openInputStream(uri) ?: return@withContext null
            input.use { source ->
                target.outputStream().use { sink -> source.copyTo(sink) }
            }
        } catch (e: Exception) {
            target.delete()
            return@withContext null
        }
        if (target.isFile && target.length() > 0L) target.absolutePath else null
    }

    private fun cacheFileName(message: ChatMessage, safeName: String): String {
        val prefix = message.id.filter { it.isLetterOrDigit() }.take(12).ifEmpty { "media" }
        return prefix + "-" + safeName
    }
}

private val THUMB_WIDTH = 120.dp
private val THUMB_HEIGHT = 90.dp

private const val THUMB_PIXEL_WIDTH = 480
private const val THUMB_PIXEL_HEIGHT = 360

private val thumbnailCache: LruCache<String, Bitmap> =
    object : LruCache<String, Bitmap>(16 * 1024 * 1024) {
        override fun sizeOf(key: String, value: Bitmap): Int = value.byteCount
    }

/** 图片 / 视频消息的固定尺寸圆角缩略图（视频叠加播放图标）。 */
@Composable
fun MediaThumbnail(message: ChatMessage, kind: MediaKind, modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val model = remember(message.id, message.fileUri, message.filePath) {
        message.fileUri?.takeIf { it.isNotBlank() } ?: message.filePath?.takeIf { it.isNotBlank() }
    }
    var bitmap by remember(message.id, model) { mutableStateOf<Bitmap?>(null) }
    LaunchedEffect(model, kind) {
        bitmap = if (model == null) {
            null
        } else {
            withContext(Dispatchers.IO) { loadThumbnail(context, model, kind) }
        }
    }
    Box(
        modifier = modifier
            .size(THUMB_WIDTH, THUMB_HEIGHT)
            .clip(RoundedCornerShape(12.dp))
            .background(MaterialTheme.colorScheme.surfaceVariant),
        contentAlignment = Alignment.Center,
    ) {
        val frame = bitmap
        if (frame != null) {
            Image(
                bitmap = frame.asImageBitmap(),
                contentDescription = message.fileName,
                modifier = Modifier.fillMaxSize(),
                contentScale = ContentScale.Crop,
            )
        } else {
            Text(
                text = if (kind == MediaKind.VIDEO) "🎬" else "🖼️",
                style = MaterialTheme.typography.headlineMedium,
            )
        }
        if (kind == MediaKind.VIDEO) {
            Box(
                modifier = Modifier
                    .size(36.dp)
                    .clip(CircleShape)
                    .background(Color.Black.copy(alpha = 0.45f)),
                contentAlignment = Alignment.Center,
            ) {
                Text("▶", color = Color.White, fontSize = 18.sp, fontWeight = FontWeight.Bold)
            }
        }
    }
}

private fun loadThumbnail(context: Context, model: String, kind: MediaKind): Bitmap? {
    thumbnailCache.get(model)?.let { return it }
    val bitmap = try {
        when (kind) {
            MediaKind.IMAGE -> loadImageThumbnail(context, model)
            MediaKind.VIDEO -> loadVideoThumbnail(context, model)
            MediaKind.OTHER -> null
        }
    } catch (e: Exception) {
        null
    }
    if (bitmap != null) thumbnailCache.put(model, bitmap)
    return bitmap
}

private fun loadImageThumbnail(context: Context, model: String): Bitmap? {
    return Glide.with(context.applicationContext)
        .asBitmap()
        .load(model)
        .override(THUMB_PIXEL_WIDTH, THUMB_PIXEL_HEIGHT)
        .centerCrop()
        .submit()
        .get()
}

private fun loadVideoThumbnail(context: Context, model: String): Bitmap? {
    val retriever = MediaMetadataRetriever()
    return try {
        if (model.startsWith("content://")) {
            retriever.setDataSource(context, Uri.parse(model))
        } else {
            retriever.setDataSource(model)
        }
        val frame = retriever.getFrameAtTime(1_000_000L, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
            ?: retriever.frameAtTime
            ?: return null
        scaleCenterCrop(frame, THUMB_PIXEL_WIDTH, THUMB_PIXEL_HEIGHT)
    } catch (e: Exception) {
        null
    } finally {
        try {
            retriever.release()
        } catch (e: Exception) {
            // 忽略释放异常
        }
    }
}

private fun scaleCenterCrop(source: Bitmap, width: Int, height: Int): Bitmap {
    val scale = maxOf(width.toFloat() / source.width, height.toFloat() / source.height)
    val scaledWidth = (source.width * scale).toInt().coerceAtLeast(1)
    val scaledHeight = (source.height * scale).toInt().coerceAtLeast(1)
    val scaled = Bitmap.createScaledBitmap(source, scaledWidth, scaledHeight, true)
    val left = ((scaledWidth - width) / 2).coerceIn(0, (scaledWidth - width).coerceAtLeast(0))
    val top = ((scaledHeight - height) / 2).coerceIn(0, (scaledHeight - height).coerceAtLeast(0))
    val cropWidth = minOf(width, scaledWidth)
    val cropHeight = minOf(height, scaledHeight)
    return Bitmap.createBitmap(scaled, left, top, cropWidth, cropHeight)
}
