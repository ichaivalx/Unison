package io.github.ichaivalx.unison.capture

import android.media.audiofx.AudioEffect
import android.os.Build
import android.os.Process
import org.json.JSONObject
import java.io.File
import java.util.UUID
import kotlin.concurrent.thread
import kotlin.system.exitProcess

internal object RootEvents {
    fun emit(type: String, data: Any?) { println(JSONObject().put("type", type).put("data", data ?: JSONObject.NULL)) }
    fun reply(id: Long, value: Any? = null, error: Throwable? = null) {
        println(JSONObject().put("type", "reply").put("id", id).put("result", value ?: JSONObject.NULL)
            .put("error", error?.message ?: JSONObject.NULL).put("cancelled", error is InterruptedException))
    }
}

object CaptureMain {
    @JvmStatic private external fun installTerminationHandler(): Int
    @JvmStatic private external fun waitForTermination(): Int
    @Volatile private var source: SourceSession? = null
    private val sourceLifecycle = Any()
    private val sourceEvents = Any()
    private var media: RootMedia? = null
    private var latencyUs = 50_000L
    private var delayUs = 0L
    private var channelDelays = emptyMap<String, Long>()
    private var excludeUid = -1
    @JvmStatic fun main(args: Array<String>) {
        try {
            excludeUid = args[0].toInt()
            check(Process.myUid() == 0) { "root is required" }
            val apk = System.getProperty("java.class.path")!!.substringBefore(File.pathSeparator)
            val library = System.getProperty("unison.capture.library") ?: "$apk!/lib/${Build.SUPPORTED_ABIS.first()}/libunison_capture.so"
            System.load(library)
            check(installTerminationHandler() == 0)
            Runtime.getRuntime().addShutdownHook(Thread({ shutdown() }, "root-shutdown"))
            thread(name = "root-signal", isDaemon = true) { waitForTermination(); shutdown(); exitProcess(0) }
            val context = RootContext.create()
            media = RootMedia(context)
            RootEvents.emit("ready", JSONObject().put("available", available()).put("pid", Process.myPid()))
            System.`in`.bufferedReader().forEachLine { line ->
                var id = 0L
                try {
                    val request = JSONObject(line); id = request.getLong("id")
                    val data = request.optJSONObject("args") ?: JSONObject()
                    val value: Any? = when (request.getString("method")) {
                        "available" -> available()
                        "startSource" -> synchronized(sourceLifecycle) {
                            check(available()) { "Unison effect module is not active or has a different version" }
                            closeSource(); latencyUs = data.getLong("latencyUs"); delayUs = data.getLong("localDelayUs")
                            channelDelays = delays(data.getJSONObject("channelDelays"))
                            check(delayUs >= 0)
                            val session = SourceSession(excludeUid, latencyUs, delayUs, channelDelays) { failed, _ -> if (source === failed) exitProcess(1) }
                            synchronized(sourceEvents) { source = session }
                            try { session.start() } catch (error: Throwable) { closeSource(); throw error }
                            null
                        }
                        "stopSource" -> { closeSource(); publishStopped(); null }
                        "setSourceLatencyUs" -> { val value = data.getLong("value"); source?.setLatency(value); latencyUs = value; publishStopped(); null }
                        "setLocalDelayUs" -> { val value = data.getLong("value"); check(value >= 0); source?.setDelay(value); delayUs = value; publishStopped(); null }
                        "setChannelDelays" -> { val value = delays(data.getJSONObject("delays")); source?.setChannelDelays(value); channelDelays = value; null }
                        "calibrate" -> {
                            val session = checkNotNull(source) { "Source is not running" }
                            val ids = data.getJSONArray("receiverIds").let { array -> List(array.length()) { array.getLong(it) } }
                            val bands = data.getJSONArray("bands").let { array -> List(array.length()) { array.getString(it) } }
                            val replyId = id
                            session.calibrate(ids, bands, { publish(session, "calibration", it) }, { result, error -> RootEvents.reply(replyId, result, error) })
                            return@forEachLine
                        }
                        "cancelCalibration" -> { source?.cancelCalibration(); null }
                        "mediaSnapshot" -> media?.snapshot()
                        "mediaCommand" -> { media?.command(data.getString("value")); null }
                        "mediaSeek" -> { media?.seek(data.getLong("value")); null }
                        else -> error("Unknown root command")
                    }
                    RootEvents.reply(id, value)
                } catch (error: Throwable) { RootEvents.reply(id, error = error) }
            }
        } catch (error: Throwable) {
            closeSource()
            RootEvents.emit("source", stopped().put("error", error.message))
        } finally { shutdown() }
        exitProcess(0)
    }
    private fun available(): Boolean = AudioEffect.queryEffects()?.any {
        it.uuid == UUID.fromString("8e2581c2-3d9a-4e15-a77a-617f6f9e8202") && it.implementor == "Unison/6"
    } == true
    private fun delays(json: JSONObject): Map<String, Long> = json.keys().asSequence().associateWith { json.getLong(it) }
        .also { check(it.values.all { delay -> delay >= 0 }) }
    private fun stopped() = JSONObject().put("running", false).put("latencyUs", latencyUs).put("localDelayUs", delayUs)
        .put("sessions", org.json.JSONArray()).put("uncaptured", org.json.JSONArray()).put("receiverIds", org.json.JSONArray()).put("error", JSONObject.NULL)
    internal fun publish(session: SourceSession, type: String, value: JSONObject) = synchronized(sourceEvents) {
        // 快照在调用处构造，不能在持有发布锁时再获取音效锁。
        if (source === session) RootEvents.emit(type, value)
    }
    private fun publishStopped() = synchronized(sourceEvents) { if (source == null) RootEvents.emit("source", stopped()) }
    private fun closeSource() = synchronized(sourceLifecycle) {
        val previous = synchronized(sourceEvents) { source.also { source = null } }
        previous?.close()
    }
    private fun shutdown() { closeSource(); media?.close() }
}
