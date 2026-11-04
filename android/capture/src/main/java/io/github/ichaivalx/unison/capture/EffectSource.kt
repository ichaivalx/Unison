package io.github.ichaivalx.unison.capture

import android.media.audiofx.AudioEffect
import java.util.UUID

internal class EffectSource {
    private var socket = -1
    private var effect: AudioEffect? = null
    private external fun openTap(): Int
    private external fun readTap(fd: Int): ByteArray?
    private external fun closeTap(fd: Int)

    fun start(localDelayMs: Int) {
        PlaybackCapture.systemContext()
        socket = openTap()
        val constructor = AudioEffect::class.java.getDeclaredConstructor(UUID::class.java, UUID::class.java,
            Int::class.javaPrimitiveType, Int::class.javaPrimitiveType).apply { isAccessible = true }
        val instance = constructor.newInstance(
            UUID.fromString("8e2581c2-3d9a-4e15-a77a-617f6f9e8201"),
            UUID.fromString("8e2581c2-3d9a-4e15-a77a-617f6f9e8202"), 0, 0)
        effect = instance
        setLocalDelay(localDelayMs)
        check(instance.setEnabled(true) == AudioEffect.SUCCESS) { "Cannot enable Unison Tap" }
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

    fun read(): ByteArray? = readTap(socket)

    fun close() {
        try {
            effect?.let { instance ->
                try { instance.setEnabled(false) } finally { instance.release() }
            }
        } finally {
            effect = null
            closeTap(socket)
            socket = -1
        }
    }
}
