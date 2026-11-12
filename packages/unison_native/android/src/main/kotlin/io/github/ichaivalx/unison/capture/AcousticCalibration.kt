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
    private val latencyUs: Long,
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
    private var cancelRequested = false
    @Volatile private var window: Window? = null
    @Volatile private var micOriginNs: Long? = null
    @Volatile private var micReadFrames = 0L
    @Volatile private var micTimestampFrame = 0L
    @Volatile private var microphoneFailure: Throwable? = null
    @Volatile private var recorder: AudioRecord? = null
    @Volatile private var tone: Tone? = null
    private val control = Any()
    private val tones = Any()
    private var pendingTone: ShortArray? = null
    private val inputEffects = mutableListOf<AudioEffect>()
    private var worker: Thread? = null
    private var micThread: Thread? = null
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

    /**
     * 测试音的一种播放方式，[rate] 为轨道自己的采样率。
     * - powerSaving：省电模式，AudioTrack 加上 FLAG_DEEP_BUFFER，走大缓冲通道。
     * - lowLatencyResampled：请求低延迟（FAST），输出策略因此选快速输出；采样率故意与原生输出不同，
     *   AudioFlinger 不让它走快速路径，成为快速输出线程上的普通轨道（可挂音效），与请求快速轨道而被
     *   降级的播放器（如 OpenSL ES 播 44.1kHz）同路。不带标志的普通轨道在不少设备上会被策略改走大缓冲。
     */
    private class Request(val name: String, val mode: Int, val bufferMs: Int, val rate: Int)
    private val requests = listOf(
        Request("powerSaving", AudioTrack.PERFORMANCE_MODE_POWER_SAVING, 200, RATE),
        Request("lowLatencyResampled", AudioTrack.PERFORMANCE_MODE_LOW_LATENCY, 40,
            if (source.outputSampleRate() == 44_100) 48_000 else 44_100),
    )

    /** 测试音轨道及其写入线程；挂载效果被拒时 [attached] 为 false，不播放 */
    private inner class Tone(val request: Request) {
        val track: AudioTrack
        val attached: Boolean
        @Volatile var stopped = false
        private val writer: Thread?

        init {
            val rate = request.rate
            val format = AudioFormat.Builder().setSampleRate(rate).setChannelMask(AudioFormat.CHANNEL_OUT_STEREO)
                .setEncoding(AudioFormat.ENCODING_PCM_16BIT).build()
            track = AudioTrack.Builder().setAudioAttributes(AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_MEDIA).setContentType(AudioAttributes.CONTENT_TYPE_MUSIC).build())
                .setAudioFormat(format).setTransferMode(AudioTrack.MODE_STREAM)
                .setPerformanceMode(request.mode)
                .setBufferSizeInBytes(maxOf(AudioTrack.getMinBufferSize(rate, AudioFormat.CHANNEL_OUT_STEREO,
                    AudioFormat.ENCODING_PCM_16BIT), rate * request.bufferMs / 1000 * 4)).build()
            writer = try {
                sessionId = track.audioSessionId
                source.setCalibrationSession(track.audioSessionId)
                val deadline = System.nanoTime() + 3_000_000_000L
                while (track.audioSessionId !in source.activeSessions() && !source.attachFailed(track.audioSessionId)) {
                    check(System.nanoTime() < deadline) { "Calibration effect could not be attached" }; pause(20)
                }
                if (track.audioSessionId !in source.activeSessions()) null else {
                    track.play()
                    thread(name = "calibration-output", isDaemon = true) { writeAudio(this) }
                }
            } catch (error: Throwable) { track.release(); throw error }
            attached = writer != null
        }

        fun close() {
            stopped = true
            runCatching { track.pause() }
            writer?.let { joinThread(it) }
            track.release()
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
            val perDevice = bands.size * 3
            val total = (requests.size + receivers.size) * perDevice
            var step = 0
            val local = org.json.JSONArray()
            val measured = mutableSetOf<String>()
            var microphoneAnchor: Long? = null
            // 接收端在最后一个挂上效果的测试音上测量
            var playable: Request? = null
            for (request in requests) {
                tone?.close(); tone = null
                val current = Tone(request)
                tone = current
                check(!cancelled) { "校准已停止" }
                // 挂不上效果（真的拿到了快速轨道）时该通道本次没有测到
                if (!current.attached) {
                    println("INFO calibration_channel request=${request.name} rate=${request.rate} attached=false")
                    step += perDevice; continue
                }
                playable = request
                // 测试音须确实落在已确定的通道上；与已测通道相同时不重复测量
                val channel = checkNotNull(source.channelOf(current.track.audioSessionId)) {
                    "无法确定测试音所在的输出通道（${request.name}）"
                }
                println("INFO calibration_channel request=${request.name} rate=${request.rate} channel=$channel duplicate=${channel in measured}")
                if (!measured.add(channel)) { step += perDevice; continue }
                pause(if (microphoneAnchor == null) 2500 else 1000)
                val anchor = microphoneAnchor ?: checkNotNull(micOriginNs) { "Microphone monotonic timestamp unavailable" }
                microphoneAnchor = anchor
                val values = measure(null, "本机 $channel", anchor, step, total)
                step += perDevice
                local.put(JSONObject().put("channel", channel).put("request", request.name).put("measurements", values))
            }
            val anchor = checkNotNull(microphoneAnchor)
            if (tone?.attached != true) {
                tone?.close(); tone = null
                // 先交给统一的收尾释放，再检查是否挂上
                val restored = Tone(checkNotNull(playable))
                tone = restored
                check(restored.attached) { "Calibration effect could not be attached" }
            }
            val remote = JSONObject()
            for (receiver in receivers) {
                remote.put(receiver.toString(), measure(receiver, receiver.toString(), anchor, step, total))
                step += perDevice
            }
            check(!cancelled) { "校准已停止" }
            result = JSONObject().put("local", local).put("receivers", remote)
        } catch (error: Throwable) { failure = if (cancelled) InterruptedException("Calibration cancelled") else error }
        finally {
            close()
            synchronized(control) {
                // 包括最后一次匹配及清理期间收到的取消；成功提交与取消互斥。
                if (cancelRequested) { result = null; failure = InterruptedException("Calibration cancelled") }
                isRunning = false
                complete(result, failure)
            }
        }
    }

    /** 在当前测试音上测一台设备（[receiver] 为 null 时为本机）的各频段 */
    private fun measure(receiver: Long?, name: String, microphoneAnchor: Long, firstStep: Int, total: Int): org.json.JSONArray {
        val valuesForDevice = org.json.JSONArray()
        var step = firstStep
        synchronized(control) {
            check(!cancelled)
            source.setCalibrationLocal(receiver == null)
            networkTarget = receiver
        }
        pause(maxOf(localDelayUs, latencyUs).coerceAtLeast(0) / 1000 + 500)
        for (band in bands) {
            val values = mutableListOf<Double>()
            repeat(3) { round ->
                progress(JSONObject().put("step", step).put("totalSteps", total)
                    .put("description", "$name ${band.name} ${round + 1}/3"))
                if (receiver == null || subscribed(receiver)) {
                    // 检测按取样侧的线程采样率；写入的测试音是同一信号按测试音轨道的采样率生成
                    val sine = chirp(band, round, false, RATE)
                    val cosine = chirp(band, round, true, RATE)
                    val played = chirp(band, round, false, checkNotNull(tone).request.rate)
                    val wave = ShortArray(played.size * 2) { (played[it / 2] * 0.35f * 32767).roundToInt().toShort() }
                    val periodMs = maxOf(localDelayUs, latencyUs).coerceAtLeast(0) / 1000 + 1500
                    val current = Window(((periodMs + 250) * RATE / 1000).toInt())
                    window = current
                    synchronized(tones) { pendingTone = wave }
                    pause(periodMs); window = null
                    val tap: FloatArray; val mic: FloatArray
                    synchronized(current.lock) {
                        current.frozen = true
                        tap = current.tap.copyOf(current.tapCount); mic = current.mic.copyOf(current.micCount)
                    }
                    val reference = detect(tap, sine, cosine, false, band.lookback, band.ratio)
                    val found = detect(mic, sine, cosine, true, band.lookback, band.ratio)
                    check(!cancelled) { "校准已停止" }
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
        return valuesForDevice
    }

    /** 频段的扫频信号按采样率 [rate] 取样；时长与渐变长度按 [RATE] 下的帧数定义，与采样率无关 */
    private fun chirp(band: Band, round: Int, quadrature: Boolean, rate: Int): FloatArray {
        val f0 = if (round % 2 == 0) band.low else band.high
        val f1 = if (round % 2 == 0) band.high else band.low
        val seconds = band.frames.toDouble() / RATE
        val taperSeconds = band.taper.toDouble() / RATE
        val k = ln(f1 / f0) / seconds
        val frames = (seconds * rate).roundToInt()
        return FloatArray(frames) { index ->
            val time = index.toDouble() / rate
            val phase = 2 * PI * f0 * (exp(k * time) - 1) / k
            val edge = minOf(index, frames - 1 - index).toDouble() / rate
            val taper = if (edge >= taperSeconds) 1.0 else 0.5 * (1 - cos(PI * edge / taperSeconds))
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

    private fun writeAudio(output: Tone) {
        Process.setThreadPriority(Process.THREAD_PRIORITY_AUDIO)
        val data = ShortArray(480 * 2)
        var wave: ShortArray? = null
        var position = 0
        try {
            while (!cancelled && !output.stopped) {
                if (wave == null) synchronized(tones) { wave = pendingTone; pendingTone = null; position = 0 }
                data.fill(0)
                wave?.let { samples ->
                    val count = minOf(data.size, samples.size - position)
                    samples.copyInto(data, 0, position, position + count)
                    position += count
                    if (position == samples.size) wave = null
                }
                var written = 0
                while (!cancelled && !output.stopped && written < data.size) {
                    val n = output.track.write(data, written, data.size - written, AudioTrack.WRITE_BLOCKING)
                    check(n > 0) { "测试音写入失败：$n" }
                    written += n
                }
            }
        } catch (error: Exception) { if (!cancelled && !output.stopped) microphoneFailure = error }
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
            if (!isRunning) return
            cancelRequested = true
        }
        stopAudio()
    }

    fun cancelAndWait() { cancel(); joinThread(worker) }

    private fun stopAudio() {
        synchronized(control) {
            cancelled = true
            window = null
            networkTarget = null
            source.setCalibrationSession(null)
            runCatching { source.setCalibrationLocal(true) }
        }
        runCatching { tone?.track?.pause() }
        runCatching { recorder?.stop() }
        if (Thread.currentThread() !== worker) worker?.interrupt()
    }

    private fun close() {
        stopAudio()
        tone?.close(); tone = null
        joinThread(micThread)
        inputEffects.forEach { runCatching { it.release() } }; inputEffects.clear()
        runCatching { recorder?.release() }; recorder = null
        source.setCalibrationSession(null)
    }
}
