package sh.rubric.baud.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.util.Locale

/// A place sent once is the same words on every baud: written as Location.swift's PlaceText writes
/// it, read as it reads it, and anything short of it stays a plain message.
class PlaceTextTest {
    private val pin = "📍 https://maps.apple.com/?ll="

    @Test fun roundTrip() {
        val s = PlaceText.make(40.7412, -73.9897)
        assertEquals("📍 https://maps.apple.com/?ll=40.74120,-73.98970", s)
        assertEquals(LatLon(40.7412, -73.9897), PlaceText.parse(s))
        for ((lat, lon) in listOf(0.0 to 0.0, -33.86882 to 151.20929, 89.999999 to -179.999999, 51.123455 to -0.000001, -90.0 to 180.0)) {
            val back = PlaceText.parse(PlaceText.make(lat, lon))!!
            // Five places: within half of the last one (and a hair for the double).
            assertEquals(lat, back.lat, 0.0000051)
            assertEquals(lon, back.lon, 0.0000051)
            // Read and written again, it's the same text.
            assertEquals(PlaceText.make(lat, lon), PlaceText.make(back.lat, back.lon))
        }
    }

    @Test fun writtenAsTheIPhoneWritesIt() {
        // String(format: "%.5f"): the exact value rounded half to even, its sign kept.
        assertEquals("51.12345", PlaceText.fixed5(51.123455))
        assertEquals("0.00001", PlaceText.fixed5(0.000005))
        assertEquals("0.00003", PlaceText.fixed5(0.000025))
        assertEquals("-0.00000", PlaceText.fixed5(-0.000001))
        // A dot in every language, never the phone's own comma.
        val was = Locale.getDefault()
        Locale.setDefault(Locale.GERMANY)
        try { assertEquals("${pin}48.13743,11.57549", PlaceText.make(48.13743, 11.57549)) } finally { Locale.setDefault(was) }
    }

    @Test fun readsWhatTheIPhoneReads() {
        // Swift's split drops an empty piece, and its Double takes a sign, an exponent, hexadecimal.
        assertEquals(LatLon(40.1, -73.2), PlaceText.parse("${pin}40.1,,-73.2"))
        assertEquals(LatLon(10.0, 0.5), PlaceText.parse("${pin}1e1,.5"))
        assertEquals(LatLon(16.0, 1.5), PlaceText.parse("${pin}0x10,+1.5"))
        assertEquals(LatLon(-0.0, 5.0), PlaceText.parse("${pin}-0.00000,5."))
    }

    @Test fun nearMissesStayWords() {
        val misses = listOf(
            null, "", pin,
            "https://maps.apple.com/?ll=40.74120,-73.98970",
            "📍https://maps.apple.com/?ll=40.74120,-73.98970",
            "📍 http://maps.apple.com/?ll=40.74120,-73.98970",
            "📍 https://maps.google.com/?ll=40.74120,-73.98970",
            " ${pin}40.74120,-73.98970",
            "${pin}40.74120,-73.98970 see you there",
            "${pin}40.74120,-73.98970&q=Jo",
            "${pin}40.74120",
            "${pin}40.7,-73.9,12",
            "${pin}40,74120,-73,98970",
            "${pin}90.00001,0",
            "${pin}0,-180.5",
            "${pin} 40.7,-73.9",
            "${pin}40.7 ,-73.9",
            "${pin}40.7d,-73.9",
            "${pin}NaN,0", "${pin}nan,0", "${pin}Infinity,0", "${pin}inf,0",
            "${pin}four,two",
        )
        for (s in misses) assertNull(s, PlaceText.parse(s))
    }
}
