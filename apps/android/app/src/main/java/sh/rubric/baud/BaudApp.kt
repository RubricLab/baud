// The process: opens the core once and keeps it, with the one model every screen, the service and
// the notifications read. In front or not comes from the process's lifecycle, not one screen's.
package sh.rubric.baud

import android.app.Application
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ApplicationInfo
import android.os.Build
import android.provider.Settings
import android.util.Log
import androidx.compose.runtime.mutableStateOf
import androidx.core.content.ContextCompat
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.ProcessLifecycleOwner
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import sh.rubric.baud.core.CoreSurface
import sh.rubric.baud.core.FakeCore
import sh.rubric.baud.core.RustCore
import java.io.File

class BaudApp : Application() {
    companion object {
        lateinit var app: BaudApp
            private set
        val model: AppModel? get() = if (::app.isInitialized) app.ready.value else null
        private val waiting = mutableListOf<(AppModel) -> Unit>()
        /// Runs now if the core is open, else as soon as it is (on the main thread).
        fun whenReady(f: (AppModel) -> Unit) { model?.let(f) ?: synchronized(waiting) { waiting += f } }
    }

    /// Null for the moment the core takes to open.
    val ready = mutableStateOf<AppModel?>(null)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    override fun onCreate() {
        super.onCreate()
        app = this
        Notifier.channels(this)
        // An update downloaded by a process that's gone: nothing is waiting on it now.
        Updates.clean(this)
        scope.launch {
            val core = open()
            val m = AppModel(this@BaudApp, core)
            ready.value = m
            synchronized(waiting) { waiting.toList().also { waiting.clear() } }.forEach { it(m) }
            m.scene(ProcessLifecycleOwner.get().lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED))
        }
        ProcessLifecycleOwner.get().lifecycle.addObserver(object : DefaultLifecycleObserver {
            // In front (at launch, and back from elsewhere): updates are looked for here, never
            // when only the background service is running.
            override fun onStart(owner: LifecycleOwner) { model?.scene(true); Updates.foreground(this@BaudApp) }
            override fun onStop(owner: LifecycleOwner) { model?.scene(false) }
        })
        if (applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0) debugHooks()
    }

    /// The core: baud-core (libbaud_ffi.so, uniffi over Rust) when its library is in the app, else
    /// the in-memory stand-in (FakeCore).
    /// `adb shell am start -n sh.rubric.baud.dev/sh.rubric.baud.MainActivity --es core fake` picks the stand-in
    /// (its demo people) on a build that has the library, from the next launch.
    private suspend fun open(): CoreSurface {
        val prefs = getSharedPreferences("app", Context.MODE_PRIVATE)
        // The library is in the APK uncompressed (not extracted), so ask the loader, not the disk.
        val real = prefs.getString("core", "real") != "fake" && runCatching { System.loadLibrary("baud_ffi") }.isSuccess
        if (real) {
            try {
                val c = RustCore.open(this, deviceName())
                Log.i("baud", "core: ${runCatching { RustCore.version() }.getOrDefault("baud-core")}")
                if (applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0) scope.launch {
                    kotlinx.coroutines.delay(8000)
                    c.trace().forEach { Log.i("baud", "trace: $it") }
                }
                return c
            } catch (e: Throwable) {
                Log.e("baud", "baud-core didn't open, using the stand-in: $e")
            }
        }
        Log.i("baud", "core: the in-memory stand-in")
        return withContext(Dispatchers.IO) { FakeCore(File(filesDir, "fake"), getSharedPreferences("fake", Context.MODE_PRIVATE), deviceName()) }
    }

    /// What the phone calls itself (Settings → About → Device name), else its model.
    fun deviceName(): String =
        runCatching { Settings.Global.getString(contentResolver, Settings.Global.DEVICE_NAME) }.getOrNull()?.takeIf { it.isNotBlank() } ?: Build.MODEL

    /// Debug builds: `adb shell am broadcast -a sh.rubric.baud.DEMO_SAY -p sh.rubric.baud.dev --es from Sam
    /// --es text "hi"` has a demo friend write, to see a notification with the app closed.
    private fun debugHooks() {
        val r = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                val from = intent.getStringExtra("from") ?: "Sam"
                val text = intent.getStringExtra("text") ?: "are you around?"
                whenReady { (it.core as? FakeCore)?.say(from, text) }
            }
        }
        ContextCompat.registerReceiver(this, r, IntentFilter("sh.rubric.baud.DEMO_SAY"), ContextCompat.RECEIVER_EXPORTED)
        // The links on screen as text, for a lab on the other end (a QR can't be read back from
        // adb): `adb shell am broadcast -a sh.rubric.baud.LAB_LINKS -p sh.rubric.baud.dev` logs the
        // reply the Add screen shows; `--ez invite true` makes a friend link and logs that too.
        val links = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                whenReady { m ->
                    m.join?.reply?.let { Log.i("baud", "lab reply: ${it.url}") }
                    if (intent.getBooleanExtra("invite", false)) runCatching { Log.i("baud", "lab invite: ${m.core.invite().url}") }
                }
            }
        }
        ContextCompat.registerReceiver(this, links, IntentFilter("sh.rubric.baud.LAB_LINKS"), ContextCompat.RECEIVER_EXPORTED)
    }
}
