package sh.rubric.baud

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Base64

/// An update is offered only from a record signed with baud's release key, exactly as it reads;
/// and an APK is taken only when baud's release certificate signed it.
class UpdatesTest {
    /// The record live on the site for 0.2.21, field by field (its JSON, the "\/" unescaped).
    private val live = ReleaseRecord(
        version = "0.2.21",
        dmg = "https://baud.rubric.sh/baud-0.2.21.dmg",
        sha256 = "b6598a07db0e7c7c6e1d43a15d631f8349e602b157f265db737427545128f879",
        sig = "MEUCIQC+Dvh/I+ICb1VdrL4X49cK7HoKatBAAbRT0vZMMyMQiwIgUZouj13NO2aNKphI5Abq/rUWBJMZ8f8EVsrZprwpGpk=",
        androidVersion = "0.2.21",
        apk = "https://baud.rubric.sh/baud-0.2.21.apk",
        apkSha256 = "8e31affc228966124316d4cfbb7a71e920a194aa2ed3a4ada309306d80e706e3",
    )

    @Test fun theLiveRecordIsGenuine() {
        assertEquals(
            "baud release 1\n0.2.21\nhttps://baud.rubric.sh/baud-0.2.21.dmg\nb6598a07db0e7c7c6e1d43a15d631f8349e602b157f265db737427545128f879\n0.2.21\nhttps://baud.rubric.sh/baud-0.2.21.apk\n8e31affc228966124316d4cfbb7a71e920a194aa2ed3a4ada309306d80e706e3",
            live.signed,
        )
        assertTrue(live.genuine)
        // Offered to a phone on an older version; not to one already on it.
        assertEquals(Updates.State.Available(Updates.Release("0.2.21", live.apk!!, live.apkSha256!!)), Updates.offer(live, "0.2.20"))
        assertEquals(Updates.State.Latest, Updates.offer(live, "0.2.21"))
    }

    @Test fun anyFieldChangedFails() {
        val tampered = listOf(
            live.copy(version = "0.2.22"),
            live.copy(dmg = "https://example.com/baud.dmg"),
            live.copy(sha256 = "0" + live.sha256!!.drop(1)),
            live.copy(androidVersion = "0.2.22"),
            live.copy(apk = "https://example.com/baud-0.2.21.apk"),
            live.copy(apkSha256 = "0" + live.apkSha256!!.drop(1)),
            live.copy(apkSha256 = null),
        )
        for (r in tampered) assertFalse(r.toString(), r.genuine)
        // A newer version the key didn't sign is never offered, and You says why.
        assertEquals(
            Updates.State.Failed("The site offers 0.2.22, but it isn't signed with baud's release key, so baud won't take it."),
            Updates.offer(live.copy(androidVersion = "0.2.22"), "0.2.21"),
        )
    }

    @Test fun noGoodSignatureFails() {
        for (sig in listOf(null, "", "AAAA", "not base64!", live.sig!!.replace('C', 'D'))) {
            assertFalse(sig.toString(), live.copy(sig = sig).genuine)
        }
        assertEquals(
            Updates.State.Failed("The site offers 0.2.21, but it isn't signed with baud's release key, so baud won't take it."),
            Updates.offer(live.copy(sig = null), "0.2.20"),
        )
    }

    @Test fun newer() {
        assertTrue(Updates.newer("0.2.22", "0.2.21"))
        assertTrue(Updates.newer("0.2.10", "0.2.9"))
        assertTrue(Updates.newer("1.0", "0.9.9"))
        assertFalse(Updates.newer("0.2.21", "0.2.21"))
        assertFalse(Updates.newer("0.2.20", "0.2.21"))
    }

    /// baud's release certificate, from the signed 0.2.21 APK (public: every APK carries it).
    private val release: ByteArray by lazy {
        val pem = javaClass.classLoader!!.getResource("release-cert.pem")!!.readText()
        Base64.getMimeDecoder().decode(pem.substringAfter("-----BEGIN CERTIFICATE-----").substringBefore("-----END CERTIFICATE-----"))
    }

    @Test fun theReleaseCertificate() {
        assertEquals(RELEASE_CERT, sha256Hex(release))
        assertTrue(signedByBaud(listOf(release)))
        // Not signed, signed by someone else, or by someone else as well: refused.
        assertFalse(signedByBaud(emptyList()))
        val other = release.copyOf().also { it[it.size - 1] = (it[it.size - 1] + 1).toByte() }
        assertFalse(signedByBaud(listOf(other)))
        assertFalse(signedByBaud(listOf(release, other)))
    }
}
