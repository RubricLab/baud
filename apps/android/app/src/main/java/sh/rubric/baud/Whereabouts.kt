// Where I am, the app's side (core/baud-core/src/places.rs has the rules for live shares, as
// Places.swift does on the Apple apps). Two uses, both from the composer's + (Location): one fix
// now, for a place sent once; and a live share, while the location service runs and hands the core
// a fix when I've moved 25 m or 20 s have passed, stopping the moment the last share ends. The
// platform's own LocationManager (its fused provider where there is one): nothing from Google Play
// services, no map tiles, no server. While a share runs, the connection service also says it uses
// location (Reachable.kt), so fixes keep coming with baud in the background.
package sh.rubric.baud

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.location.LocationRequest
import android.os.Build
import android.os.Bundle
import android.os.Looper
import android.util.Log
import androidx.core.content.ContextCompat
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeoutOrNull
import kotlin.coroutines.resume

class Whereabouts(private val context: Context, private val model: AppModel) : LocationListener {
    companion object {
        val PERMISSIONS = arrayOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION)
        fun granted(context: Context) = PERMISSIONS.any { ContextCompat.checkSelfPermission(context, it) == PackageManager.PERMISSION_GRANTED }
    }

    private val lm = context.getSystemService(LocationManager::class.java)
    private var on = false
    private var last: Pair<Location, Long>? = null
    /// The newest fix this phone has had, from a share or a place sent once.
    private var newest: Location? = null

    /// Where I was last seen by the location service, if it's been on.
    val lastFix: Location? get() = newest ?: lastKnown()

    /// On while any chat wants my location, off when none does; the connection service's type
    /// follows.
    fun follow() {
        val want = runCatching { model.core.wantsPlace() }.getOrDefault(false)
        if (want && !on && granted(context)) start() else if (!want && on) stop()
        if (Reachable.running) Reachable.start(context)
    }

    // MARK: once

    /// One fix now, for a place sent once: a recent one if there is one, else one asked for, ten
    /// seconds at most. Null without the permission, or when nothing came.
    suspend fun once(): Location? {
        if (!granted(context)) return null
        lastKnown()?.let { l -> if (System.currentTimeMillis() - l.time < 30_000 && l.hasAccuracy() && l.accuracy < 100f) return l.also { newest = it } }
        val lm = lm ?: return null
        return (withTimeoutOrNull(10_000) { fresh(lm) } ?: lastKnown())?.also { newest = it }
    }

    /// The next fix from any provider, the first that comes, asked for at the nearest ten metres.
    @SuppressLint("MissingPermission")
    private suspend fun fresh(lm: LocationManager): Location? = suspendCancellableCoroutine { k ->
        val listener = object : LocationListener {
            override fun onLocationChanged(location: Location) {
                runCatching { lm.removeUpdates(this) }
                if (k.isActive) k.resume(location)
            }
            override fun onProviderEnabled(provider: String) {}
            override fun onProviderDisabled(provider: String) {}
            @Deprecated("Android 10 and before") override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) {}
        }
        val providers = providers(lm)
        if (providers.isEmpty()) { k.resume(null); return@suspendCancellableCoroutine }
        for (p in providers) runCatching {
            if (Build.VERSION.SDK_INT >= 31) lm.requestLocationUpdates(p, LocationRequest.Builder(0L).setQuality(LocationRequest.QUALITY_HIGH_ACCURACY).build(), context.mainExecutor, listener)
            else lm.requestLocationUpdates(p, 0L, 0f, listener, Looper.getMainLooper())
        }.onFailure { Log.w("baud", "location once $p: $it") }
        k.invokeOnCancellation { runCatching { lm.removeUpdates(listener) } }
    }

    @SuppressLint("MissingPermission")
    private fun lastKnown(): Location? {
        val lm = lm ?: return null
        if (!granted(context)) return null
        return providers(lm).mapNotNull { runCatching { lm.getLastKnownLocation(it) }.getOrNull() }.maxByOrNull { it.time }
    }

    // MARK: live

    @SuppressLint("MissingPermission")
    private fun start() {
        val lm = lm ?: return
        on = true
        val providers = providers(lm)
        for (p in providers) runCatching {
            // Nearest ten metres, as the iPhone asks: the fused provider's balanced default is a
            // block away, and some phones give it nothing at all without the satellites.
            if (Build.VERSION.SDK_INT >= 31) lm.requestLocationUpdates(p, LocationRequest.Builder(20_000L).setMinUpdateDistanceMeters(25f).setQuality(LocationRequest.QUALITY_HIGH_ACCURACY).build(), context.mainExecutor, this)
            else lm.requestLocationUpdates(p, 20_000L, 25f, this, Looper.getMainLooper())
        }.onFailure { Log.w("baud", "location $p: $it") }
        // Where I was last, at once: friends see something before the first new fix.
        lastKnown()?.let(::send)
        Log.i("baud", "location on (${providers.joinToString()})")
    }

    private fun stop() {
        on = false
        last = null
        runCatching { lm?.removeUpdates(this) }
        Log.i("baud", "location off")
    }

    /// The platform's fused provider (Android 12+), else satellites and the network together.
    private fun providers(lm: LocationManager): List<String> =
        if (Build.VERSION.SDK_INT >= 31 && lm.hasProvider(LocationManager.FUSED_PROVIDER)) listOf(LocationManager.FUSED_PROVIDER)
        else listOf(LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER).filter { it in lm.allProviders }

    private fun send(l: Location) {
        newest = l
        val now = System.currentTimeMillis()
        last?.let { (p, at) -> if (l.distanceTo(p) < 25f && now - at < 20_000) return }
        last = l to now
        runCatching { model.core.moved(l.latitude, l.longitude, if (l.hasAccuracy()) l.accuracy.toDouble() else 100.0) }
    }

    override fun onLocationChanged(location: Location) = send(location)
    // Before Android 11 these have no default, and the platform calls them.
    override fun onProviderEnabled(provider: String) {}
    override fun onProviderDisabled(provider: String) {}
    @Deprecated("Android 10 and before") override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) {}
}
