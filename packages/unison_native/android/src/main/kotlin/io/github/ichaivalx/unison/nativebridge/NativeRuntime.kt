package io.github.ichaivalx.unison.nativebridge

import android.content.Context
import android.content.Intent
import android.media.AudioManager
import android.os.Handler
import android.os.Looper
import io.github.ichaivalx.unison.ReceiverEngine
import io.github.ichaivalx.unison.capture.SourceController
import io.flutter.plugin.common.EventChannel
import org.json.JSONObject
import org.json.JSONArray
import java.util.concurrent.CompletableFuture
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicLong

internal object NativeRuntime {
    lateinit var context: Context
    private val main = Handler(Looper.getMainLooper())
    val worker = Executors.newSingleThreadExecutor()
    @Volatile var sink: EventChannel.EventSink? = null
    @Volatile var receiverRequested = false
    @Volatile var sourceRequested = false
    @Volatile var keepAliveRequested = false
    @Volatile private var exiting = false
    private val exitEpoch = AtomicLong()
    private val serviceWaiters = mutableListOf<CompletableFuture<Any?>>()
    @Volatile private var keepAliveReady = CompletableFuture.completedFuture<Any?>(null)
    @Volatile var source = stoppedSource()
    @Volatile private var currentMedia: Any? = null
    @Volatile private var haveMedia = false
    private var lastVolume = -1.0
    private var polling = false
    private fun stoppedSource() = JSONObject().put("running", false).put("latencyUs", 50000).put("localDelayUs", 0)
        .put("sessions", JSONArray()).put("receiverIds", JSONArray()).put("error", JSONObject.NULL)
    fun initialize(value: Context) {
        context = value.applicationContext
        SourceController.onEvent = events@{ type, data ->
            if (exiting) return@events
            if (type == "source") {
                source = data as JSONObject
                sourceRequested = source.optBoolean("running")
                emit(type, source); serviceState()
            } else if (type == "media") {
                currentMedia = data; haveMedia = true; emit(type, data)
            } else if (type == "rootExit") {
                currentMedia = null; haveMedia = true; emit("media", null)
                val active = sourceRequested; sourceRequested = false
                source = source.put("running", false).put("sessions", JSONArray()).put("receiverIds", JSONArray())
                if (active && source.isNull("error")) source.put("error", "Root process exited")
                emit("source", source); serviceState()
            } else if (type == "calibration") emit(type, data)
        }
        if (!polling) { polling = true; main.post(poll) }
    }
    private val poll = object : Runnable {
        override fun run() {
            if (sink != null || receiverRequested || sourceRequested) {
                runCatching {
                    val stats = JSONObject(ReceiverEngine.statsJson())
                    val id = stats.optInt("outputDeviceId")
                    val manager = context.getSystemService(AudioManager::class.java)
                    val name = manager.getDevices(AudioManager.GET_DEVICES_OUTPUTS).firstOrNull { it.id == id }?.productName?.toString().orEmpty()
                    stats.put("outputDevice", name)
                    emit("receiver", stats)
                    val volume = volume()
                    if (volume != lastVolume) { lastVolume = volume; emit("volume", volume) }
                }
            }
            main.postDelayed(this, 250)
        }
    }
    fun listen(value: EventChannel.EventSink) {
        sink = value; emit("source", source); emit("volume", volume())
        if (haveMedia) emit("media", currentMedia)
        worker.execute {
            if (!SourceController.ensure(context)) { currentMedia = null; haveMedia = true; emit("media", null) }
            else SourceController.request("mediaSnapshot").whenComplete { value, error ->
                if (error == null) { currentMedia = value; haveMedia = true; emit("media", value) }
            }
        }
    }
    fun detach() { sink = null; if (!receiverRequested && !sourceRequested && !keepAliveRequested) { currentMedia = null; haveMedia = false; worker.execute { SourceController.shutdown() } } }
    fun emit(type: String, value: Any?) { main.post { sink?.success(mapOf("type" to type, "data" to convert(value))) } }
    private fun convert(value: Any?): Any? = when (value) {
        null, JSONObject.NULL -> null
        is JSONObject -> value.keys().asSequence().associateWith { convert(value.opt(it)) }
        is JSONArray -> List(value.length()) { convert(value.opt(it)) }
        else -> value
    }
    fun root(method: String, args: JSONObject = JSONObject()): CompletableFuture<Any?> {
        val future = CompletableFuture<Any?>()
        val epoch = exitEpoch.get()
        worker.execute {
            try {
                check(!exiting && epoch == exitEpoch.get()) { "Unison 已退出" }
                check(SourceController.ensure(context)) { "Root is unavailable" }
                SourceController.request(method, args).whenComplete { result, error ->
                    if (error != null) future.completeExceptionally(error) else future.complete(convert(result))
                }
            } catch (error: Throwable) { future.completeExceptionally(error) }
        }
        return future
    }
    fun startSource(args: JSONObject): CompletableFuture<Any?> {
        val epoch = exitEpoch.get()
        check(!exiting) { "Unison 正在退出" }
        sourceRequested = true
        return keepService().thenCompose {
            check(!exiting && epoch == exitEpoch.get()) { "Unison 已退出" }
            root("startSource", args)
        }.whenComplete { _, error -> if (error != null && epoch == exitEpoch.get()) { sourceRequested = false; serviceState() } }
    }
    fun startReceiver(host: String): CompletableFuture<Any?> {
        val epoch = exitEpoch.get()
        return keepAliveReady.thenCompose { background {
            // 前台阶段已建立服务；远端命令到来时只使用该服务，不从后台启动新的 FGS。
            check(!exiting && epoch == exitEpoch.get()) { "Unison 已退出" }
            check(keepAliveRequested && AudioService.instance != null) { "请先在前台开启 Unison 常驻" }
            try { receiverRequested = true; check(ReceiverEngine.start(host)) { "Cannot start receiver" }; serviceState(); forceWifi(true) }
            catch (error: Throwable) { receiverRequested = false; serviceState(); throw error }
            null
        } }
    }
    fun stopReceiver() = background { receiverRequested = false; ReceiverEngine.stop(); forceWifi(false); serviceState(); null }
    fun stopSource(): CompletableFuture<Any?> = if (exiting) CompletableFuture.completedFuture(null)
        else root("stopSource").whenComplete { _, _ -> sourceRequested = false; serviceState() }
    fun setKeepAlive(on: Boolean): CompletableFuture<Any?> {
        check(!exiting) { "Unison 正在退出" }
        keepAliveRequested = on
        if (!on) { serviceState(); return CompletableFuture.completedFuture(null) }
        keepAliveReady = keepService().whenComplete { _, error -> if (error != null) { keepAliveRequested = false; serviceState() } }
        return keepAliveReady
    }
    fun holdsService() = keepAliveRequested || sourceRequested || receiverRequested
    private fun keepService(): CompletableFuture<Any?> {
        val future = CompletableFuture<Any?>()
        main.post {
            if (AudioService.instance != null) { AudioService.instance?.refresh(); future.complete(null) }
            else {
                serviceWaiters.add(future)
                try { context.startForegroundService(Intent(context, AudioService::class.java).setAction("keep")) }
                catch (error: Throwable) { serviceWaiters.remove(future); future.completeExceptionally(error) }
            }
        }
        return future
    }
    fun serviceStarted() { val waiting = serviceWaiters.toList(); serviceWaiters.clear(); waiting.forEach { it.complete(null) } }
    fun notificationExit() {
        if (exiting) return
        exiting = true; exitEpoch.incrementAndGet()
        keepAliveRequested = false; receiverRequested = false; sourceRequested = false
        // 先通知控制面停止远端命令和重连；清理顺序在同一 worker 中执行。
        emit("exit", null)
        worker.execute {
            try {
                ReceiverEngine.stop(); forceWifi(false); SourceController.shutdown()
            } finally {
                source = source.put("running", false).put("sessions", JSONArray()).put("receiverIds", JSONArray())
                currentMedia = null; haveMedia = true
                emit("source", source); emit("media", null)
                exiting = false; serviceState()
            }
        }
        serviceState()
    }
    private fun serviceState() { main.post { AudioService.instance?.refresh() } }
    fun background(block: () -> Any?): CompletableFuture<Any?> {
        val future = CompletableFuture<Any?>()
        worker.execute { try { future.complete(block()) } catch (error: Throwable) { future.completeExceptionally(error) } }
        return future
    }
    private var wifiAttempted = false
    private fun forceWifi(enabled: Boolean) {
        if (!enabled && !wifiAttempted) return
        wifiAttempted = enabled
        runCatching {
            val process = ProcessBuilder("su", "-c", "cmd wifi force-low-latency-mode ${if (enabled) "enabled" else "disabled"}")
                .redirectErrorStream(true).start()
            process.outputStream.close()
            if (!process.waitFor(10, java.util.concurrent.TimeUnit.SECONDS)) process.destroy()
            else process.inputStream.close()
        }
    }
    fun volume(): Double {
        val audio = context.getSystemService(AudioManager::class.java)
        return audio.getStreamVolume(AudioManager.STREAM_MUSIC).toDouble() / audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
    }
    fun setVolume(value: Double) {
        require(value in 0.0..1.0)
        val audio = context.getSystemService(AudioManager::class.java)
        audio.setStreamVolume(AudioManager.STREAM_MUSIC, (value * audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC)).toInt(), 0)
        lastVolume = volume(); emit("volume", lastVolume)
    }
}
