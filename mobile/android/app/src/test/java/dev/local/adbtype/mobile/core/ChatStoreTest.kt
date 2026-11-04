package dev.local.adbtype.mobile.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class ChatStoreTest {

    @get:Rule
    val temp = TemporaryFolder()

    private fun textMessage(
        text: String,
        direction: ChatDirection,
        peerName: String = "电脑",
    ): ChatMessage = ChatMessage(
        direction = direction,
        peerName = peerName,
        kind = ChatKind.TEXT,
        text = text,
    )

    @Test
    fun appendsAndReloadsFromDisk() {
        val store = ChatStore(temp.root)
        store.append("peer-1", textMessage("hello", ChatDirection.OUTGOING))
        store.append("peer-1", textMessage("收到", ChatDirection.INCOMING))

        val reloaded = ChatStore(temp.root)
        val messages = reloaded.messagesFor("peer-1")
        assertEquals(2, messages.size)
        assertEquals("hello", messages[0].text)
        assertEquals(ChatDirection.OUTGOING, messages[0].direction)
        assertEquals("收到", messages[1].text)
        assertEquals(ChatDirection.INCOMING, messages[1].direction)
        assertEquals("电脑", messages[1].peerName)
    }

    @Test
    fun eachPeersConversationIsIndependent() {
        val store = ChatStore(temp.root)
        store.append("peer-1", textMessage("给电脑 A", ChatDirection.OUTGOING))
        store.append("peer-2", textMessage("给电脑 B", ChatDirection.OUTGOING))
        store.append("peer-2", textMessage("电脑 B 的回复", ChatDirection.INCOMING))

        store.messagesFor("peer-1").let { messages ->
            assertEquals(1, messages.size)
            assertEquals("给电脑 A", messages[0].text)
        }
        store.messagesFor("peer-2").let { messages ->
            assertEquals(2, messages.size)
        }

        val reloaded = ChatStore(temp.root)
        assertEquals(1, reloaded.messagesFor("peer-1").size)
        assertEquals(2, reloaded.messagesFor("peer-2").size)
    }

    @Test
    fun clearOnlyAffectsRequestedPeer() {
        val store = ChatStore(temp.root)
        store.append("peer-1", textMessage("a", ChatDirection.OUTGOING))
        store.append("peer-2", textMessage("b", ChatDirection.OUTGOING))
        store.clear("peer-1")

        assertTrue(store.messagesFor("peer-1").isEmpty())
        assertEquals(1, store.messagesFor("peer-2").size)
        val reloaded = ChatStore(temp.root)
        assertTrue(reloaded.messagesFor("peer-1").isEmpty())
        assertEquals(1, reloaded.messagesFor("peer-2").size)
    }

    @Test
    fun keepsAtMostFiveHundredMessages() {
        val store = ChatStore(temp.root)
        repeat(505) { index ->
            store.append("peer-1", textMessage("消息 $index", ChatDirection.INCOMING))
        }
        val messages = store.messagesFor("peer-1")
        assertEquals(ChatStore.MAX_MESSAGES_PER_PEER, messages.size)
        assertEquals("消息 5", messages.first().text)
        assertEquals("消息 504", messages.last().text)
    }

    @Test
    fun preservesChineseAndEmojiAcrossReload() {
        val store = ChatStore(temp.root)
        val text = "中文 😀🎉 换行\n第二行"
        store.append("peer-1", textMessage(text, ChatDirection.INCOMING))
        val reloaded = ChatStore(temp.root)
        assertEquals(text, reloaded.messagesFor("peer-1").single().text)
    }

    @Test
    fun contentUriSurvivesReload() {
        val store = ChatStore(temp.root)
        store.append(
            "peer-1",
            ChatMessage(
                direction = ChatDirection.INCOMING,
                peerName = "电脑",
                kind = ChatKind.FILE,
                fileName = "报告.pdf",
                fileUri = "content://media/external/downloads/1234",
                fileSize = 10L,
            ),
        )
        val loaded = ChatStore(temp.root).messagesFor("peer-1").single()
        assertEquals("content://media/external/downloads/1234", loaded.fileUri)
        assertEquals(null, loaded.filePath)
        assertEquals("报告.pdf", loaded.fileName)
    }

    @Test
    fun fileMessageFieldsSurviveReload() {
        val store = ChatStore(temp.root)
        val message = ChatMessage(
            direction = ChatDirection.INCOMING,
            peerName = "电脑",
            kind = ChatKind.FILE,
            fileName = "报告 (2).pdf",
            filePath = "/data/user/0/dev.local.adbtype.mobile/files/received/报告 (2).pdf",
            fileSize = 123456L,
        )
        store.append("peer-1", message)
        val loaded = ChatStore(temp.root).messagesFor("peer-1").single()
        assertEquals(ChatKind.FILE, loaded.kind)
        assertEquals("报告 (2).pdf", loaded.fileName)
        assertEquals(message.filePath, loaded.filePath)
        assertEquals(123456L, loaded.fileSize)
    }

    @Test
    fun corruptChatFileIsTreatedAsEmpty() {
        val store = ChatStore(temp.root)
        val directory = java.io.File(temp.root, "chats")
        assertTrue(directory.mkdirs())
        java.io.File(directory, "peer-1.json").writeText("{ 这不是合法 JSON", Charsets.UTF_8)
        assertTrue(store.messagesFor("peer-1").isEmpty())
        store.append("peer-1", textMessage("恢复", ChatDirection.OUTGOING))
        assertEquals(1, store.messagesFor("peer-1").size)
    }

    @Test
    fun safePeerFileNameRejectsPathTraversal() {
        val name = ChatStore.safePeerFileName("../../etc/passwd")
        assertFalse(name.contains("/"))
        assertFalse(name.contains("\\"))
        assertTrue(name.isNotEmpty())
        assertFalse(name.startsWith(".."))

        val chatFile = ChatStore(temp.root).fileFor("../../evil")
        assertEquals(
            java.io.File(java.io.File(temp.root, "chats"), ChatStore.safePeerFileName("../../evil") + ".json"),
            chatFile,
        )
    }
}
