package dev.local.adbtype.mobile.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MediaTypeTest {

    @Test
    fun recognizesCommonImageExtensions() {
        listOf("a.jpg", "b.JPEG", "c.png", "d.gif", "e.webp", "f.bmp", "g.heic", "照片.avif", "x.jfif")
            .forEach { name ->
                assertEquals(name, MediaKind.IMAGE, MediaType.of(name))
                assertTrue(name, MediaType.isImage(name))
                assertFalse(name, MediaType.isVideo(name))
            }
    }

    @Test
    fun recognizesCommonVideoExtensions() {
        listOf("a.mp4", "b.MOV", "c.m4v", "d.mkv", "e.webm", "f.3gp", "视频.ts", "g.mpeg")
            .forEach { name ->
                assertEquals(name, MediaKind.VIDEO, MediaType.of(name))
                assertTrue(name, MediaType.isVideo(name))
                assertFalse(name, MediaType.isImage(name))
            }
    }

    @Test
    fun otherFilesStayFileCards() {
        listOf("a.pdf", "b.txt", "c.zip", "d.docx", "README", "e.apk", "f.bin")
            .forEach { name -> assertEquals(name, MediaKind.OTHER, MediaType.of(name)) }
    }

    @Test
    fun handlesNullEmptyAndWeirdNames() {
        assertEquals(MediaKind.OTHER, MediaType.of(null))
        assertEquals(MediaKind.OTHER, MediaType.of(""))
        assertEquals(MediaKind.OTHER, MediaType.of("   "))
        assertEquals(MediaKind.OTHER, MediaType.of("."))
        assertEquals(MediaKind.OTHER, MediaType.of("trailing."))
        // 多点文件名取最后一段后缀
        assertEquals(MediaKind.IMAGE, MediaType.of("archive.tar.png"))
        assertEquals(MediaKind.VIDEO, MediaType.of("clip.final.mp4"))
    }

    @Test
    fun uppercaseAndChineseNames() {
        assertEquals(MediaKind.IMAGE, MediaType.of("截图 2026.PNG"))
        assertEquals(MediaKind.VIDEO, MediaType.of("旅行.VLOG.MP4"))
        assertEquals(MediaKind.OTHER, MediaType.of("说明 文档.TXT"))
    }
}
