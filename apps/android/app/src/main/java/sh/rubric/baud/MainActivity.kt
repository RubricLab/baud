// The one window: baud's tones over everything, the link or notification that opened it handed to
// the model, and notifications asked for at the first launch (a messenger is no use if it can't
// say a message came).
package sh.rubric.baud

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.core.content.ContextCompat
import sh.rubric.baud.ui.BaudTheme
import sh.rubric.baud.ui.Root
import sh.rubric.baud.ui.Tones

class MainActivity : ComponentActivity() {
    private val ask = registerForActivityResult(ActivityResultContracts.RequestPermission()) {}

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        handle(intent)
        askForNotifications()
        val app = application as BaudApp
        setContent {
            val model by app.ready
            val dark = isSystemInDarkTheme()
            val m = model
            val tones = remember(m?.accentHex, dark) { Tones.make(m?.accentHex, dark) }
            BaudTheme(tones) {
                if (m == null) Box(Modifier.fillMaxSize().background(tones.surface)) else Root(m)
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handle(intent)
    }

    override fun onStart() {
        super.onStart()
        // Back in front: the connection service again, if it's wanted and was stopped.
        BaudApp.whenReady { m -> if (m.named && m.staying && !Reachable.running) Reachable.start(this) }
    }

    private fun handle(intent: Intent?) {
        intent ?: return
        val prefs = getSharedPreferences("app", Context.MODE_PRIVATE)
        // Debug launches (adb): `--es core fake|real`, `--ez demo true`, `--es accent 0090FF|none`.
        intent.getStringExtra("core")?.let { prefs.edit().putString("core", it).commit(); finishAffinity(); Runtime.getRuntime().exit(0) }
        val demo = intent.getBooleanExtra("demo", false)
        val accent = intent.getStringExtra("accent")
        val conv = intent.getStringExtra("conversation")
        val url = intent.dataString?.takeIf { it.startsWith("baud://") || it.startsWith("https://baud.rubric.sh/") }
        BaudApp.whenReady { m ->
            if (demo) m.startDemo()
            accent?.let { m.pickAccent(if (it == "none") null else it) }
            conv?.let { m.reveal = it }
            url?.let { m.open(it) }
        }
    }

    private fun askForNotifications() {
        if (Build.VERSION.SDK_INT < 33) return
        val prefs = getSharedPreferences("app", Context.MODE_PRIVATE)
        if (prefs.getBoolean("askedNotifications", false)) return
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) return
        prefs.edit().putBoolean("askedNotifications", true).apply()
        ask.launch(Manifest.permission.POST_NOTIFICATIONS)
    }
}
