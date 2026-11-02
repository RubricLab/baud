// Updates without a store (apps/mac/Updates.swift's words): baud.rubric.sh/releases.json is read
// at launch and when You opens; its "android" record names the newest version and its APK. When
// it is newer than this one, You says so and Download opens the APK's address, so the system's
// installer takes it from there. Nothing is installed by the app itself.
package sh.rubric.baud

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.util.Log
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.time.Instant

object Updates {
    const val FEED = "https://baud.rubric.sh/releases.json"

    data class Release(val version: String, val apk: String, val sha256: String?)
    sealed interface State {
        data object Idle : State
        data object Checking : State
        data object Latest : State
        data class Available(val release: Release) : State
        data object Failed : State
    }

    var state by mutableStateOf<State>(State.Idle); private set
    var checkedAt by mutableStateOf<Instant?>(null); private set
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    /// At most two words, for the app card: "Up to date · 3:41 PM", "0.2.13 available", "Checking…".
    fun word(clock: (Instant) -> String): String = when (val s = state) {
        State.Idle -> ""
        State.Checking -> "Checking…"
        State.Latest -> "Up to date" + (checkedAt?.let { " · " + clock(it) } ?: "")
        is State.Available -> "${s.release.version} available"
        State.Failed -> "Couldn't check" + (checkedAt?.let { " · " + clock(it) } ?: "")
    }

    fun current(context: Context): String =
        runCatching { context.packageManager.getPackageInfo(context.packageName, 0).versionName }.getOrNull() ?: "0"

    /// Read the feed, unless it was read in the last minute.
    fun check(context: Context) {
        if (state == State.Checking) return
        checkedAt?.let { if (it.isAfter(Instant.now().minusSeconds(60))) return }
        val mine = current(context)
        if (state !is State.Available) state = State.Checking
        scope.launch {
            val r = runCatching { withContext(Dispatchers.IO) { fetch() } }
            checkedAt = Instant.now()
            state = r.fold(
                onSuccess = { rel -> if (rel != null && newer(rel.version, mine)) State.Available(rel) else State.Latest },
                onFailure = { Log.i("baud", "updates: $it"); State.Failed },
            )
        }
    }

    /// The system takes the APK from here: the browser downloads it, the installer asks.
    fun download(context: Context, release: Release) {
        runCatching { context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(release.apk)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
    }

    private fun fetch(): Release? {
        val c = (URL(FEED).openConnection() as HttpURLConnection).apply { connectTimeout = 8000; readTimeout = 8000; useCaches = false }
        try {
            if (c.responseCode != 200) throw IllegalStateException("HTTP ${c.responseCode}")
            val a = JSONObject(c.inputStream.bufferedReader().readText()).optJSONObject("android") ?: return null
            val v = a.optString("version"); val apk = a.optString("apk")
            if (v.isEmpty() || !apk.startsWith("https://")) return null
            return Release(v, apk, a.optString("sha256").ifEmpty { null })
        } finally { c.disconnect() }
    }

    /// "0.2.13" over "0.2.12": numerically, part by part.
    fun newer(a: String, b: String): Boolean {
        val x = a.split(".").map { it.toIntOrNull() ?: 0 }; val y = b.split(".").map { it.toIntOrNull() ?: 0 }
        for (i in 0 until maxOf(x.size, y.size)) {
            val d = x.getOrElse(i) { 0 } - y.getOrElse(i) { 0 }
            if (d != 0) return d > 0
        }
        return false
    }
}
