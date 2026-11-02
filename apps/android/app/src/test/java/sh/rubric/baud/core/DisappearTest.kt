package sh.rubric.baud.core

import org.junit.Assert.assertEquals
import org.junit.Test

/// The words for disappearing messages say what baud-core and BaudCore say (core/vectors).
class DisappearTest {
    @Test fun words() {
        assertEquals(listOf("5m", "1h", "8h", "1d", "1w", "4w"), listOf(300, 3600, 28_800, 86_400, 604_800, 2_419_200).map(::disappearShort))
        assertEquals(listOf("1 second", "45 seconds", "90 seconds", "1 minute", "90 minutes", "2 days", "4 weeks"), listOf(1, 45, 90, 60, 5400, 172_800, 2_419_200).map(::disappearAfter))
        assertEquals("Ana set messages to disappear 1 day after they're read", disappearLine("Ana", 86_400))
        assertEquals("You turned off disappearing messages", disappearLine("You", 0))
    }
}
