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
    private val localDelayUs: Long,
    private val receivers: List<Long>,
    private val requestedBands: List<String>,
    private val subscribed: (Long) -> Boolean,
    private val progress: (JSONObject) -> Unit,
    private val complete: (JSONObject?, Throwable?) -> Unit,
) {
    companion object {
        private const val RATE = 48_000
        private fun frameNs(frames: Long) = frames / RATE * 1_000_000_000L + frames % RATE * 1_000_000_000L / RATE
    }
    private data class Band(val name: String, val low: Double, val high: Double, val frames: Int,
        val taper: Int, val lookback: Int, val ratio: Double)
    private val bands = requestedBands.map { name -> when (name) {
        "midHigh" -> Band(name, 1000.0, 8000.0, 16800, 384, 720, 0.5)
        "lowMid" -> Band(name, 250.0, 700.0, 9600, 960, 2400, 0.3)
        "bass" -> Band(name, 80.0, 250.0, 14400, 960, 2400, 0.3)
        else -> error("Unknown calibration band $name")
    } }
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
    @Volatile var networkTarget: Long? = null
        private set
    @Volatile var sessionId: Int? = null
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
    private external fun detect(samples: FloatArray, sine: FloatArray, cosine: FloatArray, directSound: Boolean, lookback: Int, ratio: Double): DoubleArray?

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
        var result: JSONObject? = null
        var failure: Throwable? = null
        try {
            if (bands.isEmpty()) {
                result = JSONObject().put("local", org.json.JSONArray()).put("receivers", JSONObject().apply {
                    receivers.forEach { put(it.toString(), org.json.JSONArray()) }
                })
                return
            }
            openMicrophone()
            val format = AudioFormat.Builder().setSampleRate(RATE).setChannelMask(AudioFormat.CHANNEL_OUT_STEREO)
                .setEncoding(AudioFormat.ENCODING_PCM_16BIT).build()
            val track = AudioTrack.Builder().setAudioAttributes(AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_MEDIA).setContentType(AudioAttributes.CONTENT_TYPE_MUSIC).build())
                .setAudioFormat(format).setTransferMode(AudioTrack.MODE_STREAM)
                .setPerformanceMode(AudioTrack.PERFORMANCE_MODE_POWER_SAVING)
                .setBufferSizeInBytes(maxOf(AudioTrack.getMinBufferSize(RATE, AudioFormat.CHANNEL_OUT_STEREO,
                    AudioFormat.ENCODING_PCM_16BIT), RATE / 5 * 4)).build()
            player = track; sessionId = track.audioSessionId
            source.setCalibrationSession(track.audioSessionId)
            source.setCalibrationLocal(true)
            val deadline = System.nanoTime() + 3_000_000_000L
            while (track.audioSessionId !in source.activeSessions()) {
                check(System.nanoTime() < deadline) { "Calibration effect could not be attached" }; pause(20)
            }
            track.play()
            playThread = thread(name = "calibration-output", isDaemon = true) { writeAudio(track) }
            pause(2500)
            val microphoneAnchor = checkNotNull(micOriginNs) { "Microphone monotonic timestamp unavailable" }
            val total = (receivers.size + 1) * bands.size * 3
            var step = 0
            val local = org.json.JSONArray()
            val remote = JSONObject()
            for (receiver in listOf<Long?>(null) + receivers) {
                val valuesForDevice = org.json.JSONArray()
                val name = receiver?.toString() ?: "本机"
                synchronized(control) {
                    check(!cancelled)
                    source.setCalibrationLocal(receiver == null)
                    networkTarget = receiver
                }
                pause(maxOf(localDelayUs, latencyUs.toLong()).coerceAtLeast(0) / 1000 + 500)
                for (band in bands) {
                    val values = mutableListOf<Double>()
                    repeat(3) { round ->
                        progress(JSONObject().put("step", step).put("totalSteps", total)
                            .put("description", "$name ${band.name} ${round + 1}/3"))
                        if (receiver == null || subscribed(receiver)) {
                            val sine = chirp(band, round, false)
                            val cosine = chirp(band, round, true)
                            val tone = ShortArray(band.frames * 2) { (sine[it / 2] * 0.35f * 32767).roundToInt().toShort() }
                            val periodMs = maxOf(localDelayUs, latencyUs.toLong()).coerceAtLeast(0) / 1000 + 1500
                            val current = Window(((periodMs + 250) * RATE / 1000).toInt())
                            window = current
                            synchronized(tones) { pendingTone = tone }
                            pause(periodMs); window = null
                            val tap: FloatArray; val mic: FloatArray
                            synchronized(current.lock) {
                                current.frozen = true
                                tap = current.tap.copyOf(current.tapCount); mic = current.mic.copyOf(current.micCount)
                            }
                            val reference = detect(tap, sine, cosine, false, band.lookback, band.ratio)
                            val found = detect(mic, sine, cosine, true, band.lookback, band.ratio)
                            if (!current.gap && reference != null && found != null && reference[1] >= 8 &&
                                reference[2] >= 0.1 && found[1] >= 8 && found[2] >= 0.1) {
                                val tapTime = current.tapNs + reference[0] * 1_000_000_000.0 / RATE
                                val micTime = microphoneAnchor + (current.micFirstFrame + found[0]) * 1_000_000_000.0 / RATE
                                values.add((micTime - tapTime) / 1000.0)
                            }
                        }
                        ++step
                        progress(JSONObject().put("step", step).put("totalSteps", total)
                            .put("description", "$name ${band.name} ${round + 1}/3"))
                    }
                    val sorted = values.sorted()
                    val spread = if (sorted.isEmpty()) null else (sorted.last() - sorted.first()).toLong()
                    val median = if (sorted.size < 2 || spread!! > 5000) null else
                        ((sorted[(sorted.size - 1) / 2] + sorted[sorted.size / 2]) / 2).toLong()
                    valuesForDevice.put(JSONObject().put("band", band.name).put("arrivalUs", median ?: JSONObject.NULL)
                        .put("spreadUs", spread ?: JSONObject.NULL).put("rounds", values.size))
                }
                if (receiver == null) { for (i in 0 until valuesForDevice.length()) local.put(valuesForDevice.get(i)) }
                else remote.put(receiver.toString(), valuesForDevice)
            }
            result = JSONObject().put("local", local).put("receivers", remote)
        } catch (error: Throwable) { failure = if (cancelled) InterruptedException("Calibration cancelled") else error }
        finally {
            close(); isRunning = false
            complete(result, failure)
        }
    }

    private fun chirp(band: Band, round: Int, quadrature: Boolean): FloatArray {
        val f0 = if (round % 2 == 0) band.low else band.high
        val f1 = if (round % 2 == 0) band.high else band.low
        val k = ln(f1 / f0) / (band.frames.toDouble() / RATE)
        return FloatArray(band.frames) { index ->
            val phase = 2 * PI * f0 * (exp(k * index / RATE) - 1) / k
            val edge = minOf(index, band.frames - 1 - index)
            val taper = if (edge >= band.taper) 1.0 else 0.5 * (1 - cos(PI * edge / band.taper))
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
            networkTarget = null
            source.setCalibrationSession(null)
            runCatching { source.setCalibrationLocal(true) }
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
