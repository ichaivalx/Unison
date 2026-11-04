package io.github.ichaivalx.unison.capture

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.AudioPlaybackConfiguration
import android.media.audiofx.AudioEffect
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import java.util.UUID
import kotlin.concurrent.thread

internal class EffectSource {
    private class Session(val uid: Int, val id: Int, val effect: AudioEffect) {
        @Volatile var io: Int? = null
    }
    private val lock = Any()
    private val sessions = linkedMapOf<Int, Session>()
    private val failed = mutableSetOf<Int>()
    private var socket = -1
    private var factory: IBinder? = null
    private lateinit var manager: AudioManager
    private val callbacks = HandlerThread("effect-sessions")
    private lateinit var handler: Handler
    private var excludeUid = -1
    @Volatile private var needsSessionLookup = false
    @Volatile private var unresolvedClients = emptySet<Pair<Int, Int>>()
    @Volatile private var playingSessions = emptySet<Int>()
    @Volatile private var delayUs = 0L
    @Volatile private var outputMuted = false
    @Volatile private var calibrationSession: Int? = null
    @Volatile private var calibrationLocal = true
    @Volatile private var deathReason: String? = null
    @Volatile private var closed = false
    private var healthThread: Thread? = null
    private val deathRecipient = IBinder.DeathRecipient { deathReason = "HAL effect factory binder died" }
    private val callback = object : AudioManager.AudioPlaybackCallback() {
        override fun onPlaybackConfigChanged(configs: MutableList<AudioPlaybackConfiguration>) {
            refresh(configs)
        }
    }
    private val constructor = AudioEffect::class.java.getDeclaredConstructor(UUID::class.java, UUID::class.java,
        Int::class.javaPrimitiveType, Int::class.javaPrimitiveType).apply { isAccessible = true }
    private val setParameter = AudioEffect::class.java.getDeclaredMethod("setParameter", Int::class.javaPrimitiveType,
        ByteArray::class.java).apply { isAccessible = true }
    private val setInteger = AudioEffect::class.java.getDeclaredMethod("setParameter", Int::class.javaPrimitiveType,
        Int::class.javaPrimitiveType).apply { isAccessible = true }
    private val getParameter = AudioEffect::class.java.getDeclaredMethod("getParameter", Int::class.javaPrimitiveType,
        ByteArray::class.java).apply { isAccessible = true }
    private val getUid = AudioPlaybackConfiguration::class.java.getDeclaredMethod("getClientUid")
    private val getPid = AudioPlaybackConfiguration::class.java.getDeclaredMethod("getClientPid")
    private val getSession = AudioPlaybackConfiguration::class.java.getDeclaredMethod("getSessionId")
    private val isActive = AudioPlaybackConfiguration::class.java.getDeclaredMethod("isActive")
    private external fun openTap(): Int
    private external fun readTap(fd: Int): ByteArray?
    private external fun closeTap(fd: Int)

    fun start(appUid: Int, localDelayUs: Long) {
        val context = RootContext.create()
        excludeUid = appUid
        delayUs = localDelayUs
        manager = AudioManager::class.java.getDeclaredConstructor(Context::class.java).newInstance(context)
        socket = openTap()
        val binder = Class.forName("android.os.ServiceManager").getDeclaredMethod("checkService", String::class.java)
            .invoke(null, "android.hardware.audio.effect.IFactory/default") as? IBinder
        check(binder != null) { "HAL effect factory is unavailable" }
        factory = binder
        binder.linkToDeath(deathRecipient, 0)
        callbacks.start()
        handler = Handler(callbacks.looper)
        manager.registerAudioPlaybackCallback(callback, handler)
        handler.post { refresh() }
        // 探测不占采集线程；HAL 死亡后只退出，不重新创建效果。
        healthThread = thread(name = "effect-health", isDaemon = true) {
            while (!closed) {
                val snapshot = synchronized(lock) { sessions.values.toList() }
                for (session in snapshot) {
                    try {
                        check(session.effect.hasControl() && session.effect.enabled) { "lost control or disabled" }
                        val value = ByteArray(8)
                        check(getParameter.invoke(session.effect, 1, value) == 8) { "health getParameter failed" }
                    } catch (error: Exception) {
                        if (!closed && synchronized(lock) { sessions[session.id] === session }) {
                            deathReason = "AudioEffect invalid session=${session.id}: ${error.cause ?: error}"
                            return@thread
                        }
                    }
                }
                if (needsSessionLookup) handler.post { refresh() }
                try { Thread.sleep(1000) } catch (_: InterruptedException) { return@thread }
            }
        }
        println("INFO effect=Unison_Tap attach=active_sessions exclude_uid=$appUid local_delay_ms=$localDelayUs")
    }

    private fun refresh(configs: List<AudioPlaybackConfiguration>? = null) {
        if (closed) return
        try { reconcile(configs ?: manager.activePlaybackConfigurations) } catch (error: Exception) {
            if (!closed) deathReason = "Playback configuration failed: ${error.cause ?: error}"
        }
    }

    private fun reconcile(configs: List<AudioPlaybackConfiguration>) {
        if (closed || deathReason != null) return
        val wanted = linkedMapOf<Int, Int>()
        val unknown = mutableSetOf<Pair<Int, Int>>()
        for (config in configs) {
            val usage = config.audioAttributes.usage
            if (isActive.invoke(config) != true || usage !in intArrayOf(AudioAttributes.USAGE_MEDIA,
                    AudioAttributes.USAGE_GAME, AudioAttributes.USAGE_UNKNOWN)) continue
            val uid = getUid.invoke(config) as Int
            if (uid < 0 || uid == excludeUid) continue
            val session = getSession.invoke(config) as Int
            // session 0 是输出混音；AAudio 的 NONE(-1) 不等于底层 AudioTrack 没有会话。
            if (session > 0) wanted[session] = uid
            else if (session < 0) unknown.add(uid to (getPid.invoke(config) as Int))
        }
        needsSessionLookup = unknown.isNotEmpty()
        val unresolved = unknown.toMutableSet()
        if (unknown.isNotEmpty()) {
            // 只查询缺失编号的活跃客户端；不在会话锁内等待 dumpsys，采集不受影响。
            val dump = ProcessBuilder("dumpsys", "media.audio_flinger").redirectErrorStream(true).start()
            val row = Regex("""^\s*(?:F\d+\s+)?\d+\s+yes\s+(\d+)\s*/\s*(\d+)\s+(\d+)\s+\d+\s+\S+\s+0x[0-9a-fA-F]+\s+\S+\s+\S+\s+\d+\s+\d+\s+(\d+)\s+""")
            var output = false
            dump.inputStream.bufferedReader().useLines { lines -> lines.forEach { line ->
                if (line.startsWith("Output thread ")) output = true
                if (line.trim() == "Local log:" || line.startsWith("Input thread ")) output = false
                if (output) row.find(line)?.let { match ->
                    val pid = match.groupValues[1].toInt()
                    val uid = match.groupValues[2].toInt()
                    val id = match.groupValues[3].toInt()
                    val usage = match.groupValues[4].toInt()
                    if ((uid to pid) in unknown && id > 0 && usage in intArrayOf(AudioAttributes.USAGE_MEDIA,
                            AudioAttributes.USAGE_GAME, AudioAttributes.USAGE_UNKNOWN)) {
                        wanted[id] = uid
                        unresolved.remove(uid to pid)
                    }
                }
            } }
            dump.waitFor()
        }
        unresolvedClients = unresolved
        calibrationSession?.let { wanted[it] = android.os.Process.myUid() }
        playingSessions = wanted.keys.toSet()
        synchronized(lock) {
            if (closed || deathReason != null) return@synchronized
            for (id in sessions.keys.toList()) if (id !in wanted) {
                val session = sessions.remove(id)!!
                release(session)
                println("INFO effect_detached uid=${session.uid} session=$id io=${session.io ?: "pending"}")
            }
            failed.retainAll(wanted.keys)
            for ((id, uid) in wanted) {
                if (id in sessions || id in failed) continue
                var instance: AudioEffect? = null
                try {
                    instance = constructor.newInstance(UUID.fromString("8e2581c2-3d9a-4e15-a77a-617f6f9e8201"),
                        UUID.fromString("8e2581c2-3d9a-4e15-a77a-617f6f9e8202"), 0, id)
                    check(setParameter.invoke(instance, 1, java.nio.ByteBuffer.allocate(8).order(java.nio.ByteOrder.LITTLE_ENDIAN).putLong(delayUs).array()) == AudioEffect.SUCCESS) { "Cannot set local delay" }
                    if (shouldMute(id)) check(setInteger.invoke(instance, 2, 1) == AudioEffect.SUCCESS) { "Cannot mute local effect" }
                    check(instance.setEnabled(true) == AudioEffect.SUCCESS) { "Cannot enable effect" }
                    sessions[id] = Session(uid, id, instance)
                    println("INFO effect_attached uid=$uid session=$id local_delay_us=$delayUs")
                } catch (error: Exception) {
                    runCatching { instance?.release() }
                    failed.add(id)
                    // FAST/DIRECT 等拒绝挂载时保持播放器原路播放；不循环创建或改动其音量。
                    println("ERROR effect_attach uid=$uid session=$id error=${error.cause ?: error}")
                }
            }
        }
    }

    fun setLocalDelay(us: Long) {
        require(us >= 0)
        synchronized(lock) {
            delayUs = us
            val bytes = java.nio.ByteBuffer.allocate(8).order(java.nio.ByteOrder.LITTLE_ENDIAN).putLong(us).array()
            for (session in sessions.values) check(setParameter.invoke(session.effect, 1, bytes) == AudioEffect.SUCCESS) { "Cannot set local delay" }
        }
    }

    fun supportsUnprocessedMic(): Boolean = manager.getProperty(AudioManager.PROPERTY_SUPPORT_AUDIO_SOURCE_UNPROCESSED) == "true"

    fun setCalibrationSession(id: Int?) {
        calibrationSession = id
        if (!closed && ::handler.isInitialized) handler.post { refresh() }
    }

    fun setOutputMuted(muted: Boolean) = synchronized(lock) {
        outputMuted = muted
        if (closed || deathReason != null || factory?.isBinderAlive != true) return@synchronized
        try {
            for (session in sessions.values) check(setInteger.invoke(session.effect, 2, if (shouldMute(session.id)) 1 else 0) == AudioEffect.SUCCESS) {
                "Cannot change local mute session=${session.id}"
            }
        } catch (error: Exception) {
            // 恢复失败则结束音源，通过释放效果恢复原路播放，不能留下持续静音。
            if (!muted) deathReason = "Cannot restore local output: ${error.cause ?: error}"
            throw error
        }
    }

    private fun shouldMute(id: Int) = if (calibrationSession != null) id != calibrationSession || !calibrationLocal else outputMuted
    fun setCalibrationLocal(audible: Boolean) { calibrationLocal = audible; setOutputMuted(false) }
    fun sessionStatus(): org.json.JSONArray = synchronized(lock) {
        org.json.JSONArray(sessions.values.map { session -> org.json.JSONObject().put("uid", session.uid).put("sessionId", session.id)
            .put("packageName", runCatching { RootContext.create().packageManager.getPackagesForUid(session.uid)?.firstOrNull() }.getOrNull() ?: org.json.JSONObject.NULL) })
    }

    fun acceptStream(session: Int, io: Int): Boolean = synchronized(lock) {
        val entry = sessions[session] ?: return@synchronized false
        entry.io = io
        true
    }

    fun activeSessions(): Set<Int> = synchronized(lock) { sessions.keys.toSet() }

    fun hasOtherPlayback(except: Int? = null): Boolean = playingSessions.any { it != except } || unresolvedClients.isNotEmpty()

    fun status(): String = synchronized(lock) {
        "sessions=[${sessions.values.joinToString(",") { "${it.uid}/${it.id}/io:${it.io ?: "pending"}" }}] " +
            "attach_failed=[${failed.joinToString(",")}] " +
            "local_muted=$outputMuted " +
            "session_lookup_pending=[${unresolvedClients.joinToString(",") { "${it.first}/${it.second}" }}]"
    }

    fun read(): ByteArray? {
        checkAlive()
        val data = readTap(socket)
        checkAlive()
        return data
    }

    private fun checkAlive() {
        if (factory?.isBinderAlive != true) deathReason = deathReason ?: "HAL effect factory is dead"
        deathReason?.let { error(it) }
    }

    private fun release(session: Session) {
        if (deathReason == null && factory?.isBinderAlive == true) {
            if (shouldMute(session.id)) runCatching { setInteger.invoke(session.effect, 2, 0) }
            try { session.effect.setEnabled(false) } finally { session.effect.release() }
        }
    }

    fun close() {
        closed = true
        healthThread?.interrupt()
        if (::handler.isInitialized) manager.unregisterAudioPlaybackCallback(callback)
        callbacks.quitSafely()
        synchronized(lock) {
            for (session in sessions.values) runCatching { release(session) }
                .onFailure { println("ERROR release_effect session=${session.id} error=$it") }
            sessions.clear()
        }
        runCatching { factory?.unlinkToDeath(deathRecipient, 0) }
        factory = null
        closeTap(socket)
        socket = -1
    }
}
