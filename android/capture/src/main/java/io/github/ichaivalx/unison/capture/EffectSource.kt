package io.github.ichaivalx.unison.capture

import android.media.audiofx.AudioEffect
import android.os.IBinder
import java.util.UUID
import kotlin.concurrent.thread

internal class EffectSource {
    private var socket = -1
    private var effect: AudioEffect? = null
    private var factory: IBinder? = null
    @Volatile private var deathReason: String? = null
    @Volatile private var closed = false
    private var healthThread: Thread? = null
    private val deathRecipient = IBinder.DeathRecipient { deathReason = "HAL effect factory binder died" }
    private external fun openTap(): Int
    private external fun readTap(fd: Int): ByteArray?
    private external fun closeTap(fd: Int)

    fun start(localDelayMs: Int) {
        PlaybackCapture.systemContext()
        socket = openTap()
        val binder = Class.forName("android.os.ServiceManager").getDeclaredMethod("checkService", String::class.java)
            .invoke(null, "android.hardware.audio.effect.IFactory/default") as? IBinder
        check(binder != null) { "HAL effect factory is unavailable" }
        factory = binder
        binder.linkToDeath(deathRecipient, 0)
        val constructor = AudioEffect::class.java.getDeclaredConstructor(UUID::class.java, UUID::class.java,
            Int::class.javaPrimitiveType, Int::class.javaPrimitiveType).apply { isAccessible = true }
        val instance = constructor.newInstance(
            UUID.fromString("8e2581c2-3d9a-4e15-a77a-617f6f9e8201"),
            UUID.fromString("8e2581c2-3d9a-4e15-a77a-617f6f9e8202"), 0, 0)
        effect = instance
        setLocalDelay(localDelayMs)
        check(instance.setEnabled(true) == AudioEffect.SUCCESS) { "Cannot enable Unison Tap" }
        // 健康探测不占采集线程；HAL 死亡时，即使探测中的同步 Binder 调用卡住也能退出。
        healthThread = thread(name = "effect-health", isDaemon = true) {
            while (!closed) {
                try { probeEffect() } catch (error: Exception) {
                    if (!closed) deathReason = "AudioEffect invalid: ${error.cause ?: error}"
                    return@thread
                }
                try { Thread.sleep(1000) } catch (_: InterruptedException) { return@thread }
            }
        }
        println("INFO effect=Unison_Tap session=0 local_delay_ms=$localDelayMs")
    }

    fun setLocalDelay(ms: Int) {
        require(ms >= 0) { "本机延迟不能为负数" }
        val instance = checkNotNull(effect)
        val method = AudioEffect::class.java.getDeclaredMethod("setParameter", Int::class.javaPrimitiveType,
            Int::class.javaPrimitiveType).apply { isAccessible = true }
        val result = method.invoke(instance, 1, ms) as Int
        check(result == AudioEffect.SUCCESS) { "Effect setParameter(delay=$ms) returned $result" }
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

    private fun probeEffect() {
        val instance = checkNotNull(effect)
        check(instance.hasControl() && instance.enabled) { "AudioEffect lost control or became disabled" }
        val value = IntArray(1)
        val method = AudioEffect::class.java.getDeclaredMethod("getParameter", Int::class.javaPrimitiveType,
            IntArray::class.java).apply { isAccessible = true }
        val result = method.invoke(instance, 1, value) as Int
        check(result == 4) { "AudioEffect health getParameter returned $result" }
    }

    fun close() {
        closed = true
        healthThread?.interrupt()
        try {
            effect?.takeIf { deathReason == null && factory?.isBinderAlive == true }?.let { instance ->
                try { instance.setEnabled(false) } finally { instance.release() }
            }
            // 死亡的 HAL/失效效果不再做同步 Binder 调用，也不重建；进程退出释放客户端引用。
            if (deathReason != null) println("INFO release_effect=dead_endpoint reason=$deathReason")
        } finally {
            runCatching { factory?.unlinkToDeath(deathRecipient, 0) }
            factory = null
            effect = null
            closeTap(socket)
            socket = -1
        }
    }
}
