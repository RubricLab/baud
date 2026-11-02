// Notifications (apps/shared/Notifier.swift): a new message when its chat isn't in front of you,
// and a call you missed. Made on this phone from what arrived here; nothing is pushed from
// anywhere, since there is nowhere to push from. Tapping one opens its chat.
package sh.rubric.baud

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapShader
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Shader
import android.graphics.Typeface
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.Person
import androidx.core.content.ContextCompat
import androidx.core.content.pm.ShortcutInfoCompat
import androidx.core.content.pm.ShortcutManagerCompat
import androidx.core.graphics.drawable.IconCompat
import androidx.compose.ui.graphics.toArgb
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import sh.rubric.baud.core.ConvKind
import sh.rubric.baud.core.Conversation
import sh.rubric.baud.core.ConversationId
import sh.rubric.baud.core.EventId
import sh.rubric.baud.core.UserId
import sh.rubric.baud.ui.Images
import sh.rubric.baud.ui.Tones

object Notifier {
    const val MESSAGES = "messages"
    const val CALLS = "calls"
    const val CONNECTION = "connection"
    const val CONNECTION_ID = 1

    /// Each conversation as last seen: its unread count and newest event.
    private var seen: Map<ConversationId, Pair<Int, EventId?>> = emptyMap()
    private var primed = false

    fun channels(context: Context) {
        val nm = context.getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(NotificationChannel(MESSAGES, "Messages", NotificationManager.IMPORTANCE_HIGH).apply {
            description = "A new message when its chat isn't on screen."
        })
        nm.createNotificationChannel(NotificationChannel(CALLS, "Missed calls", NotificationManager.IMPORTANCE_HIGH))
        // The quiet one: the service that keeps baud reachable says so, and nothing more.
        nm.createNotificationChannel(NotificationChannel(CONNECTION, "Connection", NotificationManager.IMPORTANCE_MIN).apply {
            description = "Shown while baud stays reachable with the app closed."
            setShowBadge(false)
        })
    }

    fun attach(context: Context, model: AppModel) { seen = model.conversations.associate { it.id to (it.unread to it.lastEvent) }; primed = model.conversations.isNotEmpty() }

    /// The conversations changed: one whose unread count went up, with someone else's message
    /// newest, notifies, unless it's the chat on screen. One read (here or on another of my
    /// devices) takes its notification away.
    fun changed(context: Context, model: AppModel, convs: List<Conversation>) {
        val now = convs.associate { it.id to (it.unread to it.lastEvent) }
        if (!primed) { primed = convs.isNotEmpty(); seen = now; return }
        val was = seen
        seen = now
        for (c in convs) {
            val w = was[c.id]
            if (c.unread == 0 && (w?.first ?: 0) > 0) { cancel(context, c.id); continue }
            val from = c.lastUser ?: continue
            if (c.unread > (w?.first ?: 0) && c.lastEvent != w?.second && from != model.me.user && !onScreen(model, c.id)) post(context, model, c, from)
        }
    }

    /// The chat is in front of the person: the app is in front and that timeline is showing.
    private fun onScreen(model: AppModel, conv: ConversationId) = model.front && model.onScreen == conv

    private fun allowed(context: Context) =
        Build.VERSION.SDK_INT < 33 || ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED

    private fun open(context: Context, conv: ConversationId): PendingIntent =
        PendingIntent.getActivity(context, conv.hashCode(), Intent(context, MainActivity::class.java).setAction(Intent.ACTION_VIEW).putExtra("conversation", conv).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)

    private fun post(context: Context, model: AppModel, c: Conversation, from: UserId) {
        if (!allowed(context)) return
        val direct = c.isDirect || c.kind == ConvKind.Home
        val tones = Tones.make(model.accentHex, false)
        model.scope.launch {
            // Each sender as a person with their face: their photo, or their initials on the disc.
            val faces = HashMap<UserId, IconCompat>()
            suspend fun face(u: UserId, name: String): IconCompat = faces.getOrPut(u) {
                val hash = if (u == model.me.user) model.me.avatar else model.contacts.firstOrNull { it.user == u }?.avatar
                val photo = hash?.let { h -> runCatching { model.core.blob(h, "") }.getOrNull()?.let { withContext(Dispatchers.IO) { Images.load(it, 256) } } }
                IconCompat.createWithBitmap(circle(photo, name, tones))
            }
            val me = Person.Builder().setName(model.me.name.ifEmpty { "You" }).setKey(model.me.user).setIcon(face(model.me.user, model.me.name)).build()
            val events = runCatching { model.core.events(c.id, null, 20) }.getOrDefault(emptyList())
                .filter { !it.mine && it.type == sh.rubric.baud.core.EventType.Message && (it.text != null || it.attachments.isNotEmpty()) }.takeLast(c.unread.coerceIn(1, 6))
            val style = NotificationCompat.MessagingStyle(me)
            if (!direct) style.setConversationTitle(model.title(c)).setGroupConversation(true)
            var sender: Person? = null
            for (e in events) {
                val name = model.name(e.user)
                val p = Person.Builder().setName(name).setKey(e.user).setIcon(face(e.user, name)).build()
                sender = p
                style.addMessage(NotificationCompat.MessagingStyle.Message(e.text ?: (if (e.attachments.any { it.isImage }) "Photo" else "File"), e.at.toEpochMilli(), p))
            }
            if (events.isEmpty()) {
                val name = model.name(from)
                sender = Person.Builder().setName(name).setKey(from).setIcon(face(from, name)).build()
                style.addMessage(c.lastText ?: "New message", c.lastAt.toEpochMilli(), sender)
            }
            // A conversation shortcut: the system files it under Conversations, with the face.
            val shortcut = ShortcutInfoCompat.Builder(context, c.id)
                .setShortLabel(model.title(c)).setLongLived(true)
                .setIntent(Intent(context, MainActivity::class.java).setAction(Intent.ACTION_VIEW).putExtra("conversation", c.id))
                .setIcon(if (direct) face(from, model.name(from)) else IconCompat.createWithBitmap(circle(null, model.title(c), tones)))
                .apply { sender?.takeIf { direct }?.let { setPerson(it) } }
                .build()
            runCatching { ShortcutManagerCompat.pushDynamicShortcut(context, shortcut) }
            val n = NotificationCompat.Builder(context, MESSAGES)
                .setSmallIcon(R.drawable.ic_mark)
                .setStyle(style)
                .setShortcutId(c.id)
                .setCategory(NotificationCompat.CATEGORY_MESSAGE)
                .setContentIntent(open(context, c.id))
                .setAutoCancel(true)
                .setNumber(c.unread)
                // The swatch itself: the system draws it as an accent on its own grey, where the loud
                // tone (near-black for orange, near-white for the deep ones) would vanish.
                .setColor(model.accentHex?.let { runCatching { android.graphics.Color.parseColor("#$it") }.getOrNull() } ?: tones.strong.toArgb())
                .build()
            if (allowed(context)) runCatching { NotificationManagerCompat.from(context).notify(c.id, 0, n) }
        }
    }

    /// A call that rang here and nobody answered (calls aren't in this version; kept for them).
    fun missedCall(context: Context, model: AppModel, name: String, conv: ConversationId, video: Boolean) {
        if (onScreen(model, conv) || !allowed(context)) return
        val n = NotificationCompat.Builder(context, CALLS)
            .setSmallIcon(R.drawable.ic_mark)
            .setContentTitle(name).setContentText(if (video) "Missed video call" else "Missed call")
            .setCategory(NotificationCompat.CATEGORY_MISSED_CALL)
            .setContentIntent(open(context, conv)).setAutoCancel(true).build()
        runCatching { NotificationManagerCompat.from(context).notify("call/$conv", 0, n) }
    }

    fun cancel(context: Context, conv: ConversationId) { NotificationManagerCompat.from(context).cancel(conv, 0) }
    /// The chat came on screen: what it said is read now.
    fun clearShown(context: Context, conv: ConversationId?) { conv?.let { cancel(context, it) } }

    /// The ongoing one, while baud stays reachable: quiet, one line.
    fun connection(context: Context, line: String): android.app.Notification =
        NotificationCompat.Builder(context, CONNECTION)
            .setSmallIcon(R.drawable.ic_mark)
            .setContentTitle("baud is connected")
            .setContentText(line)
            .setOngoing(true).setSilent(true).setShowWhen(false)
            .setPriority(NotificationCompat.PRIORITY_MIN)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .setContentIntent(PendingIntent.getActivity(context, 0, Intent(context, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE))
            .build()

    /// A face as a round bitmap: the photo, or the initials on the disc in the hue (Avatar's look).
    fun circle(photo: Bitmap?, name: String, tones: Tones, side: Int = 192): Bitmap {
        val out = Bitmap.createBitmap(side, side, Bitmap.Config.ARGB_8888)
        val c = Canvas(out)
        val p = Paint(Paint.ANTI_ALIAS_FLAG)
        if (photo != null) {
            val s = maxOf(side.toFloat() / photo.width, side.toFloat() / photo.height)
            val m = android.graphics.Matrix().apply { setScale(s, s); postTranslate((side - photo.width * s) / 2, (side - photo.height * s) / 2) }
            p.shader = BitmapShader(photo, Shader.TileMode.CLAMP, Shader.TileMode.CLAMP).apply { setLocalMatrix(m) }
            c.drawCircle(side / 2f, side / 2f, side / 2f, p)
            return out
        }
        p.color = tones.face.toArgb()
        c.drawCircle(side / 2f, side / 2f, side / 2f, p)
        p.color = tones.onFace.toArgb()
        p.textSize = side * 0.4f
        p.typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
        p.textAlign = Paint.Align.CENTER
        val initials = sh.rubric.baud.ui.initials(name).ifEmpty { "?" }
        c.drawText(initials, side / 2f, side / 2f - (p.descent() + p.ascent()) / 2, p)
        return out
    }
}
