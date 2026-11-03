// Updates without a store and without a server of ours (apps/mac/Updates.swift: the same record,
// the same key, the same words). The site's release record, baud.rubric.sh/releases.json, is
// signed with baud's release key, and it is read when baud comes to the front (at launch, and again
// after six hours away) and when You's Check is pressed; never by the background service. A newer
// version shows as a bar at the top of Chats and in You. One press downloads the APK inside the app
// and checks it twice: its hash against the signed record, and that it's signed with baud's release
// certificate. Then Android's PackageInstaller puts it in place (asking once, the first time, for
// "allow from this source"). Nothing downloads or installs before the press (peer/DESIGN.md, rule
// 1), and a record without a good signature is never offered.
package sh.rubric.baud

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.util.Log
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.ProcessLifecycleOwner
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.security.KeyFactory
import java.security.MessageDigest
import java.security.Signature
import java.security.spec.X509EncodedKeySpec
import java.time.Instant
import java.util.Base64

/// The public half of baud's release key (P-256, DER). Its private half never leaves the keychain
/// of the Mac that ships (scripts/sign-release.swift).
const val RELEASE_KEY = "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEriUc8b5dsaezePo8u/ieXmNxRM2le8HIbUS6Q1W7fqpeU3G2mXRZLv2ZDy2wJ7KccvS+m4hUPQYrTqqiEPmRYQ=="
/// baud's release certificate, the one every APK on the site is signed with: SHA-256 of its DER.
const val RELEASE_CERT = "0d612a2abe22ed1ffed67474cb69734e067260ac3d2906a993465c3836838c21"

/// The site's release record, as it was signed.
data class ReleaseRecord(
    val version: String,
    val dmg: String,
    val sha256: String?,
    val sig: String?,
    val androidVersion: String?,
    val apk: String?,
    val apkSha256: String?,
) {
    /// What the release key signed: these fields, in this order, on every platform.
    val signed: String
        get() = listOf("baud release 1", version, dmg, sha256 ?: "", androidVersion ?: "", apk ?: "", apkSha256 ?: "").joinToString("\n")

    /// Signed by baud's release key, exactly as it reads.
    val genuine: Boolean get() = verifySigned(signed, sig)

    companion object {
        fun parse(text: String): ReleaseRecord {
            val o = JSONObject(text)
            val a = o.optJSONObject("android")
            fun JSONObject.text(k: String): String? = opt(k) as? String
            return ReleaseRecord(
                o.getString("version"), o.getString("dmg"), o.text("sha256"), o.text("sig"),
                a?.text("version"), a?.text("apk"), a?.text("sha256"),
            )
        }
    }
}

/// A P-256 ECDSA signature (base64 DER) over `text`, checked against baud's release key.
fun verifySigned(text: String, sig: String?): Boolean = runCatching {
    val der = Base64.getDecoder().decode(sig ?: return false)
    val key = KeyFactory.getInstance("EC").generatePublic(X509EncodedKeySpec(Base64.getDecoder().decode(RELEASE_KEY)))
    Signature.getInstance("SHA256withECDSA").run { initVerify(key); update(text.toByteArray(Charsets.UTF_8)); verify(der) }
}.getOrDefault(false)

/// SHA-256, in lowercase hex.
fun sha256Hex(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

/// Signed with baud's release certificate and nothing else: every one of an APK's signers (their
/// certificates, DER) is it, and there is at least one.
fun signedByBaud(certs: List<ByteArray>): Boolean = certs.isNotEmpty() && certs.all { sha256Hex(it) == RELEASE_CERT }

object Updates {
    const val FEED = "https://baud.rubric.sh/releases.json"
    /// The released app's package: a development build (.dev) is another app, and can't take it.
    const val PACKAGE = "sh.rubric.baud"

    /// What's offered to this phone: the Android version, its APK and the APK's hash, from a signed record.
    data class Release(val version: String, val apk: String, val sha256: String)

    sealed interface State {
        data object Idle : State
        data object Checking : State
        data object Latest : State
        data class Available(val release: Release) : State
        data class Downloading(val release: Release, val progress: Float) : State
        /// Downloaded and checked; installing it waits on the person (Android's OK, or its question).
        data class Ready(val release: Release) : State
        data class Installing(val release: Release) : State
        data class Failed(val why: String) : State
    }

    /// What a record offers a phone running `mine`: a newer version, only when the record is signed.
    fun offer(r: ReleaseRecord, mine: String): State {
        val v = r.androidVersion; val apk = r.apk; val sha = r.apkSha256
        if (v.isNullOrEmpty() || apk == null || !apk.startsWith("https://") || sha.isNullOrEmpty() || !newer(v, mine)) return State.Latest
        if (!r.genuine) return State.Failed("The site offers $v, but it isn't signed with baud's release key, so baud won't take it.")
        return State.Available(Release(v, apk, sha.lowercase()))
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

    var state by mutableStateOf<State>(State.Idle); private set
    /// When the last answer came.
    var checkedAt by mutableStateOf<Instant?>(null); private set
    /// Android's OK to install apps is needed first: the sentence that sends the person to give it.
    var asking by mutableStateOf(false); private set
    private var apk: File? = null
    /// Android's own question, when it came while baud wasn't in front: asked on the next press.
    private var question: Intent? = null
    private var sentToSettings = false
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    /// The version waiting, while there is one: the bar and You's button show.
    val waiting: Release?
        get() = when (val s = state) {
            is State.Available -> s.release
            is State.Downloading -> s.release
            is State.Ready -> s.release
            is State.Installing -> s.release
            else -> null
        }

    /// A few words, for You: "Up to date · 3:41 PM", "0.2.22 available", "Checking…", "Updating…".
    fun word(clock: (Instant) -> String): String = when (val s = state) {
        State.Idle -> ""
        State.Checking -> "Checking…"
        State.Latest -> "Up to date" + (checkedAt?.let { " · " + clock(it) } ?: "")
        is State.Available -> "${s.release.version} available"
        is State.Downloading, is State.Installing -> "Updating…"
        is State.Ready -> "${s.release.version} ready to install"
        is State.Failed -> "Couldn't update" + (checkedAt?.let { " · " + clock(it) } ?: "")
    }
    /// What went wrong, in full; otherwise the few words.
    fun sentence(clock: (Instant) -> String): String = (state as? State.Failed)?.why ?: word(clock)

    fun current(context: Context): String =
        runCatching { context.packageManager.getPackageInfo(context.packageName, 0).versionName }.getOrNull() ?: "0"

    // MARK: checking

    /// Ask the site for the newest version. `quiet` (You opening) skips it if the answer is under
    /// five minutes old.
    fun check(context: Context, quiet: Boolean = false) {
        when (state) { State.Checking, is State.Downloading, is State.Ready, is State.Installing -> return; else -> {} }
        if (quiet) checkedAt?.let { if (it.isAfter(Instant.now().minusSeconds(300))) return }
        val mine = current(context)
        state = State.Checking
        scope.launch {
            val r = runCatching { withContext(Dispatchers.IO) { ReleaseRecord.parse(fetch()) } }
            checkedAt = Instant.now()
            state = r.fold(
                onSuccess = { rec ->
                    offer(rec, mine).also { if (it is State.Failed) Log.w("baud", "update: ${rec.androidVersion} offered without a good signature; ignored") }
                },
                onFailure = { Log.i("baud", "update check failed: $it"); State.Failed("Couldn't reach baud's site to check.") },
            )
        }
    }

    /// baud came to the front (and at launch): look again if it's been six hours, and carry on an
    /// install that was waiting on "allow from this source".
    fun foreground(context: Context) {
        val app = context.applicationContext
        val s = state
        if (sentToSettings && s is State.Ready && app.packageManager.canRequestPackageInstalls()) { sentToSettings = false; install(app, s.release); return }
        if (checkedAt?.isAfter(Instant.now().minusSeconds(6 * 3600)) == true) return
        check(app, quiet = true)
    }

    private fun fetch(): String {
        val c = (URL(FEED).openConnection() as HttpURLConnection).apply { connectTimeout = 8000; readTimeout = 8000; useCaches = false }
        try {
            if (c.responseCode != 200) throw IllegalStateException("HTTP ${c.responseCode}")
            return c.inputStream.bufferedReader().readText()
        } finally { c.disconnect() }
    }

    // MARK: the press

    /// Update (or Install, once it's here): the one press.
    fun update(context: Context) {
        val app = context.applicationContext
        when (val s = state) {
            is State.Available -> download(app, s.release)
            is State.Ready -> install(app, s.release)
            else -> {}
        }
    }

    private class Refusal(message: String) : Exception(message)

    private fun download(context: Context, r: Release) {
        if (context.packageName != PACKAGE) {
            state = State.Failed("This is a development build of baud, so it can't install the released one over itself.")
            return
        }
        Log.i("baud", "update: downloading ${r.version}")
        state = State.Downloading(r, 0f)
        scope.launch {
            val got = runCatching {
                withContext(Dispatchers.IO) { fetchApk(context, r) { p -> scope.launch { if (state is State.Downloading) state = State.Downloading(r, p) } } }
            }
            got.fold(
                onSuccess = { f -> apk = f; state = State.Ready(r); install(context, r) },
                onFailure = { e ->
                    Log.w("baud", "update: $e")
                    clean(context)
                    state = State.Failed((e as? Refusal)?.message ?: "The download didn't finish. Check the connection and try again.")
                },
            )
        }
    }

    /// The APK, into the app's cache, hashed as it comes; kept only if it's the one the signed
    /// record names and it's signed with baud's release certificate.
    private fun fetchApk(context: Context, r: Release, progress: (Float) -> Unit): File {
        val dir = File(context.cacheDir, "updates").apply { deleteRecursively(); mkdirs() }
        val part = File(dir, "baud-${r.version}-unchecked.apk")
        val c = (URL(r.apk).openConnection() as HttpURLConnection).apply { connectTimeout = 15_000; readTimeout = 30_000; useCaches = false }
        try {
            if (c.responseCode != 200) throw Refusal("baud's site didn't give the update (HTTP ${c.responseCode}). Try again later.")
            if (c.url.protocol != "https") throw Refusal("The update didn't come over a secure connection, so baud won't install it.")
            val total = c.contentLengthLong
            val digest = MessageDigest.getInstance("SHA-256")
            var done = 0L
            var shown = -1
            c.inputStream.use { input ->
                part.outputStream().use { out ->
                    val buf = ByteArray(64 * 1024)
                    while (true) {
                        val n = input.read(buf)
                        if (n < 0) break
                        digest.update(buf, 0, n); out.write(buf, 0, n); done += n
                        if (total > 0) { val pct = (done * 100 / total).toInt(); if (pct != shown) { shown = pct; progress(pct / 100f) } }
                    }
                }
            }
            val hash = digest.digest().joinToString("") { "%02x".format(it) }
            if (hash != r.sha256) throw Refusal("The download isn't the one baud's signed record names, so baud won't install it.")
            val (pkg, certs) = signers(context, part)
            if (!signedByBaud(certs)) throw Refusal("The app in the download isn't signed with baud's release certificate, so baud won't install it.")
            if (pkg != context.packageName) throw Refusal("The download is a different app, so baud won't install it.")
            val apk = File(dir, "baud-${r.version}.apk")
            if (!part.renameTo(apk)) throw Refusal("There isn't room on this phone for the update.")
            return apk
        } catch (e: Exception) {
            part.delete(); throw e
        } finally { c.disconnect() }
    }

    /// The package inside an APK file and the certificates it's signed with now (not ones it
    /// rotated away from).
    @Suppress("DEPRECATION")
    private fun signers(context: Context, apk: File): Pair<String?, List<ByteArray>> {
        val pm = context.packageManager
        if (Build.VERSION.SDK_INT >= 28) {
            val info = pm.getPackageArchiveInfo(apk.path, PackageManager.GET_SIGNING_CERTIFICATES) ?: return null to emptyList()
            return info.packageName to info.signingInfo?.apkContentsSigners.orEmpty().map { it.toByteArray() }
        }
        val info = pm.getPackageArchiveInfo(apk.path, PackageManager.GET_SIGNATURES) ?: return null to emptyList()
        return info.packageName to info.signatures.orEmpty().map { it.toByteArray() }
    }

    // MARK: installing

    private fun install(context: Context, r: Release) {
        val f = apk?.takeIf { it.exists() } ?: run { state = State.Available(r); return }
        // Android asked while baud was behind: ask again now, in front.
        question?.let { q ->
            question = null
            state = State.Installing(r)
            runCatching { context.startActivity(q.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }.onFailure { state = State.Ready(r) }
            return
        }
        // The first time: Android's OK to install apps, once.
        if (!context.packageManager.canRequestPackageInstalls()) { state = State.Ready(r); asking = true; return }
        Log.i("baud", "update: installing ${r.version}")
        state = State.Installing(r)
        scope.launch {
            runCatching { withContext(Dispatchers.IO) { commit(context, f) } }.onFailure { e ->
                Log.w("baud", "update: install didn't start: $e")
                clean(context)
                state = State.Failed("Android couldn't start installing the update. Try again.")
            }
        }
    }

    /// The APK into an install session of Android's, which answers through Installed.
    private fun commit(context: Context, f: File) {
        val installer = context.packageManager.packageInstaller
        val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL).apply {
            setAppPackageName(context.packageName)
            setSize(f.length())
            // An app updating itself: no question after "allow from this source" is given.
            if (Build.VERSION.SDK_INT >= 31) setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_NOT_REQUIRED)
        }
        val id = installer.createSession(params)
        try {
            installer.openSession(id).use { s ->
                s.openWrite("baud.apk", 0, f.length()).use { out -> f.inputStream().use { it.copyTo(out) }; s.fsync(out) }
                val flags = PendingIntent.FLAG_UPDATE_CURRENT or (if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0)
                val answer = PendingIntent.getBroadcast(context, id, Intent(context, Installed::class.java).setPackage(context.packageName), flags)
                s.commit(answer.intentSender)
            }
        } catch (e: Exception) {
            runCatching { installer.abandonSession(id) }
            throw e
        }
    }

    /// "Continue" on the sentence: Android's own screen for allowing installs from baud.
    fun allow(context: Context) {
        asking = false
        sentToSettings = true
        runCatching {
            context.startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${context.packageName}")).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        }.onFailure { sentToSettings = false; state = State.Failed("Android's setting for allowing baud's updates didn't open.") }
    }

    /// "Not now": the update stays ready, Install asks again.
    fun notNow() { asking = false }

    /// The downloaded file gone, whatever happened.
    fun clean(context: Context) {
        apk = null
        question = null
        runCatching { File(context.cacheDir, "updates").deleteRecursively() }
    }

    private val front: Boolean get() = ProcessLifecycleOwner.get().lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED)

    /// What Android said about the install.
    private fun answered(context: Context, status: Int, message: String?, ask: Intent?) {
        val r = waiting
        Log.i("baud", "update: install status $status${message?.let { " ($it)" } ?: ""}")
        when (status) {
            PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                if (ask == null) { clean(context); state = State.Failed("Android couldn't ask about the update. Try again."); return }
                if (front) runCatching { context.startActivity(ask.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }.onFailure { question = ask; r?.let { state = State.Ready(it) } }
                else { question = ask; r?.let { state = State.Ready(it) } }
            }
            PackageInstaller.STATUS_SUCCESS -> { clean(context); state = State.Latest }
            // Android's question was turned down: it's still here, and Install asks again.
            PackageInstaller.STATUS_FAILURE_ABORTED -> state = if (r != null && apk?.exists() == true) State.Ready(r) else State.Idle
            else -> {
                clean(context)
                state = State.Failed(
                    when (status) {
                        PackageInstaller.STATUS_FAILURE_BLOCKED -> "Android blocked the update."
                        PackageInstaller.STATUS_FAILURE_CONFLICT -> "Android says the update conflicts with the baud on this phone."
                        PackageInstaller.STATUS_FAILURE_INCOMPATIBLE -> "This phone can't run that version of baud."
                        PackageInstaller.STATUS_FAILURE_INVALID -> "Android says the download isn't a whole app."
                        PackageInstaller.STATUS_FAILURE_STORAGE -> "There isn't room on this phone for the update."
                        else -> "Android couldn't install the update" + (message?.takeIf { it.isNotBlank() }?.let { ": $it" } ?: ".")
                    },
                )
            }
        }
    }

    /// Android's answer to an install session.
    class Installed : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            val ask = if (Build.VERSION.SDK_INT >= 33) intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
            else @Suppress("DEPRECATION") intent.getParcelableExtra(Intent.EXTRA_INTENT)
            answered(
                context.applicationContext,
                intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE),
                intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE),
                ask,
            )
        }
    }
}
