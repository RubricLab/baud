package sh.rubric.baud.ui

import org.junit.Assert.assertEquals
import org.junit.Test
import java.time.Instant
import java.util.Locale

/// The words the person page and location say, as the iPhone says them. The distances are what
/// Measurement's road usage printed on a Mac for the same metres, in each place.
class LocationWordsTest {
    private val metres = listOf(5.0, 9.6, 12.0, 17.0, 23.0, 47.0, 86.0, 120.0, 123.0, 456.0, 999.0, 1234.0, 1500.0, 15678.0, 160934.0)

    @Test fun distances() {
        assertEquals(
            listOf("20 ft", "30 ft", "40 ft", "60 ft", "80 ft", "150 ft", "300 ft", "400 ft", "400 ft", "1,500 ft", "0.62 mi", "0.77 mi", "0.93 mi", "9.7 mi", "100 mi"),
            metres.map { distance(it, Locale.US) },
        )
        assertEquals(
            listOf("5 yd", "10 yd", "10 yd", "20 yd", "30 yd", "50 yd", "90 yd", "150 yd", "150 yd", "500 yd", "0.62 mi", "0.77 mi", "0.93 mi", "9.7 mi", "100 mi"),
            metres.map { distance(it, Locale.UK) },
        )
        assertEquals(
            listOf("5 m", "10 m", "10 m", "20 m", "20 m", "50 m", "90 m", "120 m", "120 m", "450 m", "1 km", "1.2 km", "1.5 km", "16 km", "161 km"),
            metres.map { distance(it, Locale("en", "AU")) },
        )
        assertEquals(
            listOf("5 m", "10 m", "10 m", "20 m", "20 m", "50 m", "90 m", "120 m", "120 m", "450 m", "1 km", "1,2 km", "1,5 km", "16 km", "161 km"),
            metres.map { distance(it, Locale.GERMANY) },
        )
        // Never closer than five metres: "within 5 m" at best.
        assertEquals("5 m", distance(1.0, Locale.GERMANY))
    }

    @Test fun liveBar() {
        val clock = { _: Instant -> "6:30 PM" }
        assertEquals("Ana is sharing live", liveLine(listOf("Ana"), false, null, clock))
        assertEquals("Ana and Jo are sharing live", liveLine(listOf("Ana", "Jo"), false, null, clock))
        assertEquals("Ana is sharing live · you too", liveLine(listOf("Ana"), true, Instant.EPOCH, clock))
        assertEquals("You're sharing live", liveLine(emptyList(), true, null, clock))
        assertEquals("You're sharing live until 6:30 PM", liveLine(emptyList(), true, Instant.EPOCH, clock))
        assertEquals("Just now", liveAgo(Instant.now().minusSeconds(20), clock))
        assertEquals("4 min ago", liveAgo(Instant.now().minusSeconds(250), clock))
        assertEquals("At 6:30 PM", liveAgo(Instant.now().minusSeconds(7200), clock))
    }

    @Test fun whoTheyAreToMe() {
        assertEquals("You", personSubtitle(true, null, null, "online", emptyList()))
        assertEquals("Friend · online", personSubtitle(false, "Ana", "Ana", "online", emptyList()))
        assertEquals("Friend · away 2 h", personSubtitle(false, "Ana", null, "away 2 h", emptyList()))
        assertEquals("Friend · online · calls themself Anastasia", personSubtitle(false, "Ana", "Anastasia", "online", emptyList()))
        assertEquals("Not your friend", personSubtitle(false, null, "Lee", "online", emptyList()))
        assertEquals("Not your friend · reached through Ana and Jo", personSubtitle(false, null, "Lee", "online", listOf("Ana", "Jo")))
    }
}
