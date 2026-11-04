package dev.local.adbtype.mobile.core

import java.io.File
import java.util.Locale

/**
 * 接收文件的文件名处理（§6）：
 * 只取路径最后一段、拒绝空 / "." / ".."、重名自动编号、拒绝路径穿越。
 */
object FileNames {

    private const val MAX_NAME_CHARS = 120

    /**
     * 把对端发来的原始文件名收敛成安全的本地文件名。
     * 返回 null 表示应当拒绝（空名、"."、".."、"含 NUL 等）。
     */
    fun sanitizeIncoming(rawName: String?): String? {
        val raw = rawName?.trim().orEmpty()
        if (raw.isEmpty()) return null
        // 同时兼容 POSIX 和 Windows 路径分隔符
        val unified = raw.replace('\\', '/')
        var name = unified.substringAfterLast('/')
        // 去掉控制字符（含 NUL），避免写文件时出问题
        name = name.filter { it.code >= 0x20 && it.code != 0x7F }
        name = name.trim()
        if (name.isEmpty() || name == "." || name == "..") return null
        if (name.length > MAX_NAME_CHARS) name = clipName(name)
        if (name.isEmpty() || name == "." || name == "..") return null
        return name
    }

    /**
     * 在已有文件名集合里为 [fileName] 找一个不重名的名字：
     * 冲突时依次尝试 "base (2).ext"、"base (3).ext"……
     * MediaStore（公共 Download）和普通目录都复用这套命名规则。
     */
    fun uniqueName(existing: Set<String>, fileName: String): String {
        if (fileName !in existing) return fileName
        val dot = fileName.lastIndexOf('.')
        val base: String
        val extension: String
        if (dot > 0 && dot < fileName.length - 1) {
            base = fileName.substring(0, dot)
            extension = fileName.substring(dot)
        } else {
            base = fileName
            extension = ""
        }
        var index = 2
        while (index <= 100_000) {
            val candidate = if (extension.isEmpty()) "$base ($index)" else "$base ($index)$extension"
            if (candidate !in existing) return candidate
            index++
        }
        // 极端情况下（十万个同名文件）退回时间戳
        return "$base-" + System.currentTimeMillis() + extension
    }

    /**
     * 在目录里为 name 找一个不冲突的文件：
     * 已存在时依次尝试 "base (2).ext"、"base (3).ext"……
     */
    fun uniqueFile(directory: File, fileName: String): File {
        val existing = directory.list()?.toSet().orEmpty()
        return File(directory, uniqueName(existing, fileName))
    }

    /** 人类可读的大小，例如 "12 B"、"1.5 KB"、"3 MB"。 */
    fun formatSize(bytes: Long): String {
        if (bytes < 0) return "未知大小"
        if (bytes < 1024) return bytes.toString() + " B"
        val units = arrayOf("KB", "MB", "GB", "TB", "PB")
        var value = bytes.toDouble() / 1024.0
        var unitIndex = 0
        while (value >= 1024.0 && unitIndex < units.size - 1) {
            value /= 1024.0
            unitIndex++
        }
        return if (value >= 100.0 || value % 1.0 == 0.0) {
            String.format(Locale.ROOT, "%.0f %s", value, units[unitIndex])
        } else {
            String.format(Locale.ROOT, "%.1f %s", value, units[unitIndex])
        }
    }

    private fun clipName(name: String): String {
        val dot = name.lastIndexOf('.')
        if (dot <= 0) return name.take(MAX_NAME_CHARS)
        val base = name.substring(0, dot)
        val extension = name.substring(dot)
        if (extension.length >= MAX_NAME_CHARS) return name.take(MAX_NAME_CHARS)
        val keepBase = MAX_NAME_CHARS - extension.length
        if (keepBase <= 0) return name.take(MAX_NAME_CHARS)
        return base.take(keepBase) + extension
    }
}
