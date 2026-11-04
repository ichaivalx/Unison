package io.github.ichaivalx.unison.capture

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.AudioTimestamp
import android.media.AudioTrack
import android.media.MediaRecorder
import android.media.audiofx.AcousticEchoCanceler
import android.media.audiofx.AudioEffect
import android.media.audiofx.AutomaticGainControl
import android.media.audiofx.NoiseSuppressor
import android.os.Process
import org.json.JSONObject
import kotlin.concurrent.thread
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.exp
import kotlin.math.ln
import kotlin.math.roundToInt
import kotlin.math.sin

/** 仅在音源进程运行；录音与 tap 保留在内存中，沿用现有 UDP 音频和时钟。 */
internal class AcousticCalibration(
    private val source: EffectSource,
    private val latencyUs: Int,
    private val localDelayMs: Int,
    private val hasSubscribers: () -> Boolean,
    private val applySettings: (Int, Int) -> Unit,
) {
    companion object {
        private const val RATE = 48_000
        private const val CHIRP_FRAMES = 16_800 // 0.35 秒
        private fun frameNs(frames: Long) = frames / RATE * 1_000_000_000L + frames % RATE * 1_000_000_000L / RATE
        private fun event(state: String, body: JSONObject.() -> Unit = {}) {
            println("CALIBRATION " + JSONObject().put("state", state).apply(body))
        }
    }

    private class Window(capacity: Int) {
        val lock = Any()
        val tap = FloatArray(capacity)
        val mic = FloatArray(capacity)
        var tapCount = 0
        var micCount = 0
        var tapNs = 0L
        var micFirstFrame = 0L
        var gap = false
        var frozen = false
    }

    @Volatile var isRunning = false
        private set
    @Volatile var networkMuted = false
        private set
    @Volatile private var cancelled = false
    @Volatile private var window: Window? = null
    @Volatile private var micOriginNs: Long? = null
    @Volatile private var micReadFrames = 0L
    @Volatile private var micTimestampFrame = 0L
    @Volatile private var microphoneFailure: Throwable? = null
    @Volatile private var recorder: AudioRecord? = null
    @Volatile private var player: AudioTrack? = null
    private val control = Any()
    private val tones = Any()
    private var pendingTone: ShortArray? = null
    private val inputEffects = mutableListOf<AudioEffect>()
    private var worker: Thread? = null
    private var micThread: Thread? = null
    private var playThread: Thread? = null
    private external fun detect(samples: FloatArray, sine: FloatArray, cosine: FloatArray, directSound: Boolean): DoubleArray?

    fun start() {
        isRunning = true
        worker = thread(name = "acoustic-calibration", isDaemon = true) { run() }
    }

    fun onTap(timeNs: Long, stereo: FloatArray) {
        val current = window ?: return
        synchronized(current.lock) {
            if (current.frozen || current.tapCount == current.tap.size) return
            if (current.tapCount == 0) current.tapNs = timeNs
            else if (abs(timeNs - current.tapNs - frameNs(current.tapCount.toLong())) > 1_000_000) current.gap = true
            val frames = minOf(stereo.size / 2, current.tap.size - current.tapCount)
            for (frame in 0 until frames) current.tap[current.tapCount++] = (stereo[frame * 2] + stereo[frame * 2 + 1]) * 0.5f
        }
    }

    private fun run() {
        var succeeded = false
        try {
            check(hasSubscribers()) { "没有接收端订阅，请先启动 PC 接收端" }
            check(!source.hasOtherPlayback()) { "请先暂停其他播放，再开始校准" }
            event("begin") { put("message", "请暂停其他播放，让 PC 扬声器的声音能传到平板麦克风") }
            openMicrophone()
            val format = AudioFormat.Builder().setSampleRate(RATE).setChannelMask(AudioFormat.CHANNEL_OUT_STEREO)
                .setEncoding(AudioFormat.ENCODING_PCM_16BIT).build()
            val track = AudioTrack.Builder().setAudioAttributes(AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_MEDIA).setContentType(AudioAttributes.CONTENT_TYPE_MUSIC).build())
                .setAudioFormat(format).setTransferMode(AudioTrack.MODE_STREAM)
                .setPerformanceMode(AudioTrack.PERFORMANCE_MODE_POWER_SAVING)
                .setBufferSizeInBytes(maxOf(AudioTrack.getMinBufferSize(RATE, AudioFormat.CHANNEL_OUT_STEREO,
                    AudioFormat.ENCODING_PCM_16BIT), RATE / 5 * 4)).build()
            player = track
            event("output") { put("session", track.audioSessionId); put("bufferFrames", track.bufferSizeInFrames); put("performance", track.performanceMode) }
            source.setCalibrationSession(track.audioSessionId)
            val deadline = System.nanoTime() + 3_000_000_000L
            while (track.audioSessionId !in source.activeSessions()) {
                check(System.nanoTime() < deadline) { "测试音效果挂载失败：${source.status()}" }
                pause(20)
            }
            track.play()
            playThread = thread(name = "calibration-output", isDaemon = true) { writeAudio(track) }
            pause(2500)
            val microphoneAnchor = checkNotNull(micOriginNs) { "麦克风单调时钟时间戳不可用" }
            // 两阶段共用同一个 getTimestamp 锚点，按已读帧数推进；共同输入延迟才能相减抵消。
            val delays = mutableListOf<List<Double>>()
            val settlingMs = maxOf(localDelayMs, latencyUs / 1000).coerceAtLeast(0) + 500L
            val periodMs = maxOf(localDelayMs, latencyUs / 1000).coerceAtLeast(0) + 1500L
            for (pc in listOf(false, true)) {
                synchronized(control) {
                    check(!cancelled) { "校准已停止" }
                    source.setOutputMuted(pc)
                    networkMuted = !pc
                }
                val side = if (pc) "PC" else "本机"
                event("phase") { put("stage", side); put("message", if (pc) "只听 PC" else "只听平板，网络音频已静音") }
                pause(settlingMs)
                val values = mutableListOf<Double>()
                repeat(3) { round ->
                    check(!source.hasOtherPlayback(track.audioSessionId)) { "检测到其他播放，请暂停后重试" }
                    check(hasSubscribers()) { "接收端订阅已断开" }
                    val sine = chirp(round, false)
                    val cosine = chirp(round, true)
                    val tone = ShortArray(CHIRP_FRAMES * 2) { (sine[it / 2] * 0.35f * 32767).roundToInt().toShort() }
                    val current = Window(((periodMs + 250) * RATE / 1000).toInt())
                    window = current
                    synchronized(tones) { pendingTone = tone }
                    pause(periodMs)
                    window = null
                    val tap: FloatArray
                    val mic: FloatArray
                    synchronized(current.lock) {
                        current.frozen = true
                        check(!current.gap) { "tap 时间轴中断，请重试" }
                        tap = current.tap.copyOf(current.tapCount)
                        mic = current.mic.copyOf(current.micCount)
                    }
                    val reference = checkNotNull(detect(tap, sine, cosine, false)) { "tap 中没有完整测试音" }
                    val received = checkNotNull(detect(mic, sine, cosine, true)) { "麦克风录音过短" }
                    val micOrigin = checkNotNull(micOriginNs)
                    val tapTime = current.tapNs + reference[0] * 1_000_000_000.0 / RATE
                    val micTime = microphoneAnchor + (current.micFirstFrame + received[0]) * 1_000_000_000.0 / RATE
                    val offset = (micTime - tapTime) / 1_000_000.0
                    val tapMatch = reference[1] >= 8 && reference[2] >= 0.1
                    val micMatch = received[1] >= 8 && received[2] >= 0.1
                    event("detection") {
                        put("stage", side); put("round", round + 1)
                        put("tapSnr", reference[1]); put("tapMatch", reference[2])
                        put("snr", received[1]); put("match", received[2])
                        put("offsetMs", offset); put("micOriginNs", micOrigin)
                        put("micAheadFrames", micTimestampFrame - micReadFrames)
                        put("tapNs", tapTime); put("micNs", micTime)
                    }
                    check(tapMatch) { "tap 扫频未可靠检出" }
                    check(micMatch) { "$side 扫频未可靠检出，请确认声音能到达麦克风并降低环境噪声" }
                    values.add(offset)
                    event("round") {
                        put("stage", side); put("round", round + 1); put("offsetMs", offset)
                        put("snr", received[1]); put("match", received[2])
                    }
                }
                check(values.max() - values.min() <= 5.0) { "$side 三轮相差超过 5ms，请保持设备位置不变并重试" }
                delays.add(values)
            }
            val local = delays[0].sorted()[1]
            val pc = delays[1].sorted()[1]
            val delta = pc - local
            val newLocal = if (delta > 0) Math.addExact(localDelayMs, delta.roundToInt()) else localDelayMs
            val newLatency = if (delta < 0) Math.addExact(latencyUs, Math.multiplyExact((-delta).roundToInt(), 1000)) else latencyUs
            synchronized(control) {
                check(!cancelled) { "校准已停止" }
                applySettings(newLatency, newLocal)
            }
            event("result") {
                put("deltaMs", delta); put("localMs", local); put("pcMs", pc)
                put("localDelayMs", newLocal); put("latencyUs", newLatency)
            }
            succeeded = true
        } catch (error: Throwable) {
            event("error") { put("message", error.message ?: error.toString()) }
        } finally {
            close()
            event("restored") { put("success", succeeded) }
            isRunning = false
        }
    }

    private fun chirp(round: Int, quadrature: Boolean): FloatArray {
        val f0 = if (round % 2 == 0) 1000.0 else 8000.0
        val f1 = if (round % 2 == 0) 8000.0 else 1000.0
        val k = ln(f1 / f0) / (CHIRP_FRAMES.toDouble() / RATE)
        return FloatArray(CHIRP_FRAMES) { index ->
            val phase = 2 * PI * f0 * (exp(k * index / RATE) - 1) / k
            val edge = minOf(index, CHIRP_FRAMES - 1 - index)
            val taper = if (edge >= 384) 1.0 else 0.5 * (1 - cos(PI * edge / 384))
            ((if (quadrature) cos(phase) else sin(phase)) * taper).toFloat()
        }
    }

    private fun openMicrophone() {
        val presets = if (source.supportsUnprocessedMic()) intArrayOf(MediaRecorder.AudioSource.UNPROCESSED,
            MediaRecorder.AudioSource.VOICE_RECOGNITION) else intArrayOf(MediaRecorder.AudioSource.VOICE_RECOGNITION)
        var failure: Throwable? = null
        for (preset in presets) {
            var input: AudioRecord? = null
            try {
                val minimum = AudioRecord.getMinBufferSize(RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
                input = AudioRecord(preset, RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT,
                    maxOf(minimum, RATE / 2 * 2))
                check(input.state == AudioRecord.STATE_INITIALIZED) { "AudioRecord 未初始化" }
                recorder = input
                for (effect in listOf(
                    if (AcousticEchoCanceler.isAvailable()) AcousticEchoCanceler.create(input.audioSessionId) else null,
                    if (NoiseSuppressor.isAvailable()) NoiseSuppressor.create(input.audioSessionId) else null,
                    if (AutomaticGainControl.isAvailable()) AutomaticGainControl.create(input.audioSessionId) else null)) {
                    if (effect != null) {
                        inputEffects.add(effect)
                        check(effect.setEnabled(false) == AudioEffect.SUCCESS && !effect.enabled) { "无法关闭麦克风预处理" }
                    }
                }
                // 先关闭预处理再开录音，避免创建效果期间产生无人读取的积压。
                input.startRecording()
                check(input.recordingState == AudioRecord.RECORDSTATE_RECORDING) { "麦克风录音未启动" }
                event("microphone") { put("source", if (preset == MediaRecorder.AudioSource.UNPROCESSED) "UNPROCESSED" else "VOICE_RECOGNITION") }
                val activeInput = checkNotNull(input)
                micThread = thread(name = "calibration-microphone", isDaemon = true) { readMicrophone(activeInput) }
                return
            } catch (error: Exception) {
                failure = error
                runCatching { input?.release() }
                inputEffects.forEach { runCatching { it.release() } }; inputEffects.clear()
                recorder = null
            }
        }
        throw IllegalStateException("无法打开麦克风：${failure?.message}", failure)
    }

    private fun readMicrophone(input: AudioRecord) {
        Process.setThreadPriority(Process.THREAD_PRIORITY_AUDIO)
        val data = ShortArray(480)
        val timestamp = AudioTimestamp()
        var readFrames = 0L
        var previousTimestamp = -1L
        try {
            while (!cancelled) {
                val count = input.read(data, 0, data.size, AudioRecord.READ_BLOCKING)
                if (cancelled) return
                check(count > 0) { "麦克风读取失败：$count" }
                if (input.getTimestamp(timestamp, AudioTimestamp.TIMEBASE_MONOTONIC) == AudioRecord.SUCCESS && timestamp.nanoTime > 0) {
                    micTimestampFrame = timestamp.framePosition
                    val origin = timestamp.nanoTime - frameNs(timestamp.framePosition)
                    if (timestamp.framePosition != previousTimestamp) {
                        micOriginNs = micOriginNs?.let { it + (origin - it) / 16 } ?: origin
                        previousTimestamp = timestamp.framePosition
                    }
                }
                window?.let { current -> synchronized(current.lock) {
                    if (!current.frozen && current.micCount < current.mic.size) {
                        if (current.micCount == 0) current.micFirstFrame = readFrames
                        val n = minOf(count, current.mic.size - current.micCount)
                        for (index in 0 until n) current.mic[current.micCount++] = data[index] / 32768f
                    }
                } }
                readFrames += count
                micReadFrames = readFrames
            }
        } catch (error: Exception) { if (!cancelled) microphoneFailure = error }
    }

    private fun writeAudio(track: AudioTrack) {
        Process.setThreadPriority(Process.THREAD_PRIORITY_AUDIO)
        val data = ShortArray(480 * 2)
        var tone: ShortArray? = null
        var position = 0
        try {
            while (!cancelled) {
                if (tone == null) synchronized(tones) { tone = pendingTone; pendingTone = null; position = 0 }
                data.fill(0)
                tone?.let { wave ->
                    val count = minOf(data.size, wave.size - position)
                    wave.copyInto(data, 0, position, position + count)
                    position += count
                    if (position == wave.size) tone = null
                }
                var written = 0
                while (!cancelled && written < data.size) {
                    val n = track.write(data, written, data.size - written, AudioTrack.WRITE_BLOCKING)
                    check(n > 0) { "测试音写入失败：$n" }
                    written += n
                }
            }
        } catch (error: Exception) { if (!cancelled) microphoneFailure = error }
    }

    private fun pause(ms: Long) {
        val until = System.nanoTime() + ms * 1_000_000
        while (System.nanoTime() < until) {
            check(!cancelled) { "校准已停止" }
            microphoneFailure?.let { throw IllegalStateException("校准音频流失败：${it.message}", it) }
            Thread.sleep(minOf(20, ((until - System.nanoTime()) / 1_000_000).coerceAtLeast(1)))
        }
    }

    fun cancel() {
        synchronized(control) {
            cancelled = true
            window = null
            networkMuted = false
            runCatching { source.setOutputMuted(false) }
        }
        runCatching { player?.pause() }
        runCatching { recorder?.stop() }
        if (Thread.currentThread() !== worker) worker?.interrupt()
    }

    private fun close() {
        cancel()
        runCatching { playThread?.join(1000) }; runCatching { micThread?.join(1000) }
        runCatching { player?.release() }; player = null
        inputEffects.forEach { runCatching { it.release() } }; inputEffects.clear()
        runCatching { recorder?.release() }; recorder = null
        source.setCalibrationSession(null)
    }
}
