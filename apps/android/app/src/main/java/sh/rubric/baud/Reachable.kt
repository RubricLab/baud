// Staying reachable with baud closed: a foreground service that keeps this phone's node online, so
// friends' messages arrive (and notify) and this phone carries for them, with no Firebase and no
// server to wake it. Started after first run and at boot; turned off from You.
//
// Why `remoteMessaging` and not `dataSync`: from Android 15 (targetSdk 35) a dataSync service is
// capped at six hours in any 24 and stopped at the limit (Service.onTimeout), and may not start from
// BOOT_COMPLETED; a messenger that must stay reachable all day can't live under either. The
// platform defines remoteMessaging for exactly this ("continue a text message from one device to
// another"): baud's node carries the person's messages between their own devices and their
// friends', peer to peer. It has no time cap and may start at boot. Before Android 14 there are no
// typed services, so it starts untyped there.
package sh.rubric.baud

import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import sh.rubric.baud.core.NetState

class Reachable : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val messaging = if (Build.VERSION.SDK_INT >= 34) ServiceInfo.FOREGROUND_SERVICE_TYPE_REMOTE_MESSAGING else 0
        // While I share where I am in a chat, the service says it uses location too, so fixes
        // keep coming with baud in the background (Whereabouts.kt). Only with the permission, and
        // only from where the system allows it (in front); else just messaging, until the next try.
        val sharing = Build.VERSION.SDK_INT >= 29 && Whereabouts.granted(this) &&
            BaudApp.model?.let { m -> runCatching { m.core.wantsPlace() }.getOrDefault(false) } == true
        val types = if (sharing) listOf(messaging or ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION, messaging) else listOf(messaging)
        val started = types.firstOrNull { type ->
            runCatching { ServiceCompat.startForeground(this, Notifier.CONNECTION_ID, Notifier.connection(this, line(null)), type) }
                .onFailure { Log.w("baud", "connection service as $type: $it") }.isSuccess
        }
        if (started == null) {
            // Not allowed from where it was asked (the background, on a newer Android): the app
            // starts it again the next time it is opened.
            stopSelf(); return START_NOT_STICKY
        }
        running = true
        BaudApp.whenReady { m -> m.serviceRunning(true); update(m) }
        return START_STICKY
    }

    override fun onDestroy() {
        running = false
        BaudApp.model?.serviceRunning(false)
        super.onDestroy()
    }

    /// The one line under "baud is connected": the status, in the words beside my face.
    private fun line(state: NetState?): String = when (state) {
        is NetState.Through -> "Through ${state.name}"
        NetState.Offline -> "Offline"
        is NetState.NotReachable -> "Not reachable"
        else -> "Online"
    }

    private fun update(m: AppModel) {
        val nm = getSystemService(android.app.NotificationManager::class.java)
        runCatching { nm.notify(Notifier.CONNECTION_ID, Notifier.connection(this, line(m.netState))) }
    }

    /// At boot and after an update: back on, if it was on and the person is set up.
    class Boot : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            val prefs = context.getSharedPreferences("app", Context.MODE_PRIVATE)
            if (prefs.getBoolean("staying", true) && prefs.getBoolean("named", false)) start(context)
        }
    }

    companion object {
        @Volatile var running = false
            private set
        fun start(context: Context) { runCatching { ContextCompat.startForegroundService(context, Intent(context, Reachable::class.java)) }.onFailure { Log.w("baud", "start: $it") } }
        fun stop(context: Context) { context.stopService(Intent(context, Reachable::class.java)) }
    }
}
