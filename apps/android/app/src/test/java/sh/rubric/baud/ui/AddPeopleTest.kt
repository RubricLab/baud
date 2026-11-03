package sh.rubric.baud.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import sh.rubric.baud.core.Contact
import java.time.Instant

/// Add people lists my friends who aren't in it yet, by name in any case, narrows them by what's
/// typed, searches only past six, and says on its button how many it adds.
class AddPeopleTest {
    private fun friend(name: String) = Contact(name.lowercase(), name, false, "", emptyList(), Instant.EPOCH)
    private val friends = listOf("sam", "Ana", "Jo", "bea", "Dana", "Maya", "Lee", "Theo").map(::friend)

    @Test fun friendsNotInItYet() {
        val shown = addable(friends, listOf("jo", "me", "lee"))
        assertEquals(listOf("Ana", "bea", "Dana", "Maya", "sam", "Theo"), shown.map { it.name })
        assertEquals(friends.size, addable(friends, listOf("me")).size)
        // No such conversation: nobody to add.
        assertTrue(addable(friends, null).isEmpty())
        assertTrue(addable(friends, friends.map { it.user }).isEmpty())
    }

    @Test fun searching() {
        val all = addable(friends, emptyList())
        assertEquals(all, matching(all, ""))
        assertEquals(all, matching(all, "   "))
        assertEquals(listOf("Ana", "Dana"), matching(all, " AN ").map { it.name })
        assertEquals(listOf("Maya"), matching(all, "y").map { it.name })
        assertTrue(matching(all, "zz").isEmpty())
    }

    @Test fun searchOnlyPastSix() {
        assertFalse(searchable(friends.take(6)))
        assertTrue(searchable(friends.take(7)))
    }

    @Test fun theButton() {
        assertEquals("Add", addWord(0))
        assertEquals("Add 1 person", addWord(1))
        assertEquals("Add 3 people", addWord(3))
    }
}
