package sh.rubric.baud.ui

import org.junit.Assert.assertEquals
import org.junit.Test

/// A link in a message is the whole link, as sent: no sentence punctuation, every dash and underscore.
class LinksTest {
    private fun found(s: String) = links(s).map { s.substring(it) }

    @Test fun wholeLinks() {
        val g = "https://baud.rubric.sh/add#ajtamrdfpb2gk4qaaebagbafaydqqcikbmga2dqpcaireeyu-culbogazdinryhi6d4aaaaaanl-au"
        assertEquals(listOf(g), found("add me $g."))
        assertEquals(listOf(g), found("($g)"))
        assertEquals(listOf("baud://add#AWYG_RGV4dGVy_abc_def-ghi_"), found("baud://add#AWYG_RGV4dGVy_abc_def-ghi_ and more"))
        assertEquals(listOf("https://en.wikipedia.org/wiki/Foo_(bar)"), found("see https://en.wikipedia.org/wiki/Foo_(bar), ok"))
        assertEquals(listOf("https://a.com/x?y=1", "HTTP://b.org"), found("https://a.com/x?y=1! and HTTP://b.org"))
        assertEquals(emptyList<String>(), found("visit https:// nothing"))
    }
}
