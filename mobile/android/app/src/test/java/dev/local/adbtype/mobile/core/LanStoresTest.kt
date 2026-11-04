package dev.local.adbtype.mobile.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class LanStoresTest {

    @get:Rule
    val temp = TemporaryFolder()

    @Test
    fun deviceIdIsStableAcrossInstances() {
        val first = LanStores(temp.root).deviceId()
        assertTrue(first.isNotBlank())
        val second = LanStores(temp.root).deviceId()
        assertEquals(first, second)
    }

    @Test
    fun pairedIdsPersistAsStringArray() {
        val stores = LanStores(temp.root)
        stores.savePaired(linkedSetOf("peer-1", "peer-2"))
        val loaded = LanStores(temp.root).loadPaired()
        assertEquals(setOf("peer-1", "peer-2"), loaded)
        assertEquals(listOf("peer-1", "peer-2"), LanJson.parse(stores.pairedFile.readText()))
    }

    @Test
    fun friendsPersistWithAliasAndLastSeen() {
        val stores = LanStores(temp.root)
        stores.saveFriends(
            listOf(
                LanFriend("peer-1", "pichs 的 MacBook Pro", "192.168.1.10", 51234, 1700000000000L, alias = "书房电脑"),
                LanFriend("peer-2", "Windows 台式机", "192.168.1.11", 51235, 1700000001000L),
            )
        )
        val loaded = LanStores(temp.root).loadFriends()
        assertEquals(2, loaded.size)
        assertEquals("书房电脑", loaded[0].alias)
        assertEquals("192.168.1.10", loaded[0].host)
        assertEquals(51234, loaded[0].port)
        assertEquals(1700000000000L, loaded[0].lastSeenMillis)
        assertEquals(null, loaded[1].alias)
    }

    @Test
    fun corruptStateFilesFallBackToEmpty() {
        val stores = LanStores(temp.root)
        stores.ensureBaseDir()
        stores.pairedFile.writeText("not-json", Charsets.UTF_8)
        stores.friendsFile.writeText("[{\"id\":]", Charsets.UTF_8)
        assertTrue(stores.loadPaired().isEmpty())
        assertTrue(stores.loadFriends().isEmpty())
    }

    @Test
    fun missingStateFilesFallBackToEmpty() {
        val stores = LanStores(temp.newFolder("empty-root"))
        assertTrue(stores.loadPaired().isEmpty())
        assertTrue(stores.loadFriends().isEmpty())
    }
}
