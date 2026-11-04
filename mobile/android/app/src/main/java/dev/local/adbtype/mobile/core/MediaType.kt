package dev.local.adbtype.mobile.core

import java.util.Locale

/** 消息里文件的媒体类型：图片 / 视频 / 其它文件。 */
enum class MediaKind {
    IMAGE,
    VIDEO,
    OTHER,
}

/**
 * 按文件名后缀判断媒体类型（纯 Kotlin，可在 JVM 单元测试）。
 * 图片/视频在聊天里显示缩略图并支持点击预览，其它文件保持文件卡片。
 */
object MediaType {

    private val IMAGE_EXTENSIONS = setOf(
        "jpg", "jpeg", "png", "gif", "webp", "bmp", "heic", "heif", "avif", "jfif",
    )

    private val VIDEO_EXTENSIONS = setOf(
        "mp4", "m4v", "mov", "mkv", "webm", "avi", "3gp", "3g2", "ts", "flv", "wmv", "mpeg", "mpg",
    )

    fun of(fileName: String?): MediaKind {
        val name = fileName?.trim().orEmpty()
        if (name.isEmpty()) return MediaKind.OTHER
        val extension = name.substringAfterLast('.', "").lowercase(Locale.ROOT)
        if (extension.isEmpty()) return MediaKind.OTHER
        return when (extension) {
            in IMAGE_EXTENSIONS -> MediaKind.IMAGE
            in VIDEO_EXTENSIONS -> MediaKind.VIDEO
            else -> MediaKind.OTHER
        }
    }

    fun isImage(fileName: String?): Boolean = of(fileName) == MediaKind.IMAGE

    fun isVideo(fileName: String?): Boolean = of(fileName) == MediaKind.VIDEO
}
