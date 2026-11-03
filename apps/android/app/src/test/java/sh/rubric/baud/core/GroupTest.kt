package sh.rubric.baud.core

import android.content.SharedPreferences
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import sh.rubric.baud.whoReacted
import java.nio.file.Files

/// Groups on the stand-in core, as the screens use them: leaving takes a group out of the list,
/// only an admin removes someone, and the Reactions sheet names who reacted ("You" first).
class GroupTest {
    private fun demo(): FakeCore =
        FakeCore(Files.createTempDirectory("baud").toFile(), Prefs(), "Pixel").apply { setName("Dex"); startDemo() }

    private fun FakeCore.group(name: String) = conversations().first { it.name == name }

    @Test fun leaving() {
        val core = demo()
        val hike = core.group("hike")
        core.leave(hike.id)
        assertTrue("a group I left is out of the list", core.conversations().none { it.id == hike.id })
        assertFalse(core.me().user in core.conversation(hike.id)!!.members)
        assertEquals("You left", core.events(hike.id).last().system)
    }

    @Test fun onlyAnAdminRemoves() {
        val core = demo()
        // Ana made the hike: I'm not its admin there.
        val hike = core.group("hike")
        val lee = core.members(hike.id).first { it.name == "Lee" }.user
        try { core.removeMember(hike.id, lee); fail("removed without being an admin") } catch (e: CoreError.NotAdmin) {}
        // The weekend is mine: Jo goes, and the line says so.
        val weekend = core.group("weekend")
        val jo = core.members(weekend.id).first { it.name == "Jo" }.user
        core.removeMember(weekend.id, jo)
        assertFalse(jo in core.conversation(weekend.id)!!.members)
        assertEquals("You removed Jo", core.events(weekend.id).last().system)
    }

    @Test fun addingAndNaming() {
        val core = demo()
        val hike = core.group("hike")
        val maya = core.contacts().first { it.name == "Maya" }.user
        core.addMember(hike.id, maya)
        assertTrue(maya in core.conversation(hike.id)!!.members)
        core.rename(hike.id, "big hike")
        assertEquals("big hike", core.conversation(hike.id)!!.name)
        assertEquals("You named it big hike", core.events(hike.id).last().system)
    }

    @Test fun reactionNames() {
        val core = demo()
        val me = core.me().user
        val weekend = core.group("weekend")
        // As the app names people: a friend by the name I gave them, anyone else by their own.
        fun names(conv: ConversationId): (UserId) -> String = { u -> core.contacts().firstOrNull { it.user == u }?.name ?: core.members(conv).first { it.user == u }.name }
        val cabin = core.events(weekend.id).first { it.text == "cabin is booked 🏡" }
        assertEquals(listOf("🙌" to listOf("You", "Jo"), "❤️" to listOf("Ana")), whoReacted(cabin.reactions, me, names(weekend.id)))
        // Mine off: Jo's stays, and the most reactions still come first.
        core.react(weekend.id, cabin.id, "🙌", false)
        core.react(weekend.id, cabin.id, "❤️", true)
        val after = core.events(weekend.id).first { it.id == cabin.id }
        assertEquals(listOf("❤️" to listOf("You", "Ana"), "🙌" to listOf("Jo")), whoReacted(after.reactions, me, names(weekend.id)))
        // Lee isn't my friend: the name on his own card.
        val hike = core.group("hike")
        val map = core.events(hike.id).first { it.text == "trail map is in the group" }
        assertEquals(listOf("👍" to listOf("You", "Lee")), whoReacted(map.reactions, me, names(hike.id)))
    }
}

/// SharedPreferences in memory, for the stand-in core.
private class Prefs : SharedPreferences {
    private val values = HashMap<String, Any?>()
    override fun getAll(): Map<String, *> = values
    override fun getString(key: String, defValue: String?) = values[key] as? String ?: defValue
    @Suppress("UNCHECKED_CAST")
    override fun getStringSet(key: String, defValues: Set<String>?) = values[key] as? Set<String> ?: defValues
    override fun getInt(key: String, defValue: Int) = values[key] as? Int ?: defValue
    override fun getLong(key: String, defValue: Long) = values[key] as? Long ?: defValue
    override fun getFloat(key: String, defValue: Float) = values[key] as? Float ?: defValue
    override fun getBoolean(key: String, defValue: Boolean) = values[key] as? Boolean ?: defValue
    override fun contains(key: String) = key in values
    override fun registerOnSharedPreferenceChangeListener(listener: SharedPreferences.OnSharedPreferenceChangeListener?) {}
    override fun unregisterOnSharedPreferenceChangeListener(listener: SharedPreferences.OnSharedPreferenceChangeListener?) {}
    override fun edit(): SharedPreferences.Editor = Editor()

    private inner class Editor : SharedPreferences.Editor {
        private fun put(key: String, value: Any?): SharedPreferences.Editor { values[key] = value; return this }
        override fun putString(key: String, value: String?) = put(key, value)
        override fun putStringSet(key: String, value: Set<String>?) = put(key, value)
        override fun putInt(key: String, value: Int) = put(key, value)
        override fun putLong(key: String, value: Long) = put(key, value)
        override fun putFloat(key: String, value: Float) = put(key, value)
        override fun putBoolean(key: String, value: Boolean) = put(key, value)
        override fun remove(key: String): SharedPreferences.Editor { values.remove(key); return this }
        override fun clear(): SharedPreferences.Editor { values.clear(); return this }
        override fun commit() = true
        override fun apply() {}
    }
}
