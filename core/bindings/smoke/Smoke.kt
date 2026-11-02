// The Kotlin bindings end to end on the JVM, against the host library: two Baud cores in one
// process meet by invite and message both ways, through the generated suspend calls, a Kotlin
// Keychain and a Kotlin Listener. `scripts/kotlin-smoke.sh` builds and runs it.
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.delay
import sh.rubric.baud.ffi.*
import java.io.File
import java.util.concurrent.ConcurrentHashMap

class Keys : Keychain {
    private val m = ConcurrentHashMap<String, ByteArray>()
    override fun get(item: String): ByteArray? = m[item]
    override fun put(item: String, bytes: ByteArray) { m[item] = bytes }
    override fun delete(item: String) { m.remove(item) }
}

class Changes(val who: String) : Listener {
    val seen = ConcurrentHashMap.newKeySet<String>()
    override fun onChange(change: Change) { seen.add(change::class.simpleName ?: "?") }
}

suspend fun until(what: String, f: () -> Boolean) {
    repeat(200) { if (f()) return; delay(50) }
    error("timed out waiting for $what")
}

fun main(args: Array<String>) = runBlocking {
    val root = File(args[0]).apply { deleteRecursively(); mkdirs() }
    println(version())
    fun config(name: String) = Config(name = name, deviceName = "$name's phone", deviceKind = DeviceKind.ANDROID, nearby = false, portmap = false)
    val ana = Baud.open(File(root, "ana").path, Keys(), config("Ana"))
    val ben = Baud.open(File(root, "ben").path, Keys(), config("Ben"))
    val heard = Changes("ben")
    val sub = ben.subscribe(heard)
    ana.setOnline(true); ben.setOnline(true)
    val link = ana.invite()
    check(parseLink(link.code)?.name == "Ana") { "the code reads as Ana's" }
    val c = ben.add(link.url)
    println("ben added ${c.name}: ${c.sentence}")
    until("the chat") { ben.conversations(Kind.CHAT).any { it.isDirect } && ana.conversations(Kind.CHAT).any { it.isDirect } }
    val conv = ana.conversations(Kind.CHAT).first { it.isDirect }.id
    val sent = ana.send(conv, Draft(text = "hello from kotlin"))
    until("ben has it") { ben.events(conv, null, 20u).any { it.text == "hello from kotlin" } }
    ben.markRead(conv, sent.id)
    until("read") { ana.delivery(conv, sent.id).best is DeliveryState.Read }
    ben.send(conv, Draft(text = "and back"))
    until("ana has it") { ana.events(conv, null, 20u).any { it.text == "and back" } }
    try { ben.send("nonsense", Draft(text = "x")); error("should throw") } catch (e: BaudException.NotMember) { println("not a member: ${e.message}") }
    println("ben heard ${heard.seen.sorted()}")
    println("delivery: ${ana.delivery(conv, sent.id).sentence}; ana's devices: ${ana.me().devices.map { "${it.name} ${it.kind} ${it.sentence}" }}")
    sub.cancel()
    ana.shutdown(); ben.shutdown()
    ana.close(); ben.close()
    println("kotlin smoke ok")
}
