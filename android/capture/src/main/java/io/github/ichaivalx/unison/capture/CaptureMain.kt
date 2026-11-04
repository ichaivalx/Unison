package io.github.ichaivalx.unison.capture

import android.media.AudioRecord
import android.media.AudioTimestamp
import android.os.Build
import android.os.Process
import java.io.File
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.NetworkInterface
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.channels.DatagramChannel
import java.nio.channels.SelectionKey
import java.nio.channels.Selector
import java.util.Collections
import java.util.Locale
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import kotlin.concurrent.thread
import kotlin.math.abs
import kotlin.system.exitProcess

/** 仅由 su + app_process 启动；线格式与 core/include/unison/protocol.h 一致。 */
object CaptureMain {
    private const val MAGIC = 0x4E534E55
    private const val SOURCE_PORT = 47800
    private const val BEACON_PORT = 47801
    private const val SAMPLE_RATE = 48_000
    private const val FRAMES = 240
    private const val AUDIO_HEADER = 28
    private const val PCM_BYTES = FRAMES * 2 * 2
    private const val SUBSCRIBE_TIMEOUT_NS = 5_000_000_000L
    private val lifecycle = Any()
    private val subscribers = ConcurrentHashMap<InetSocketAddress, Long>()
    private val packetCount = AtomicLong()
    private val subscribeCount = AtomicLong()
    private val sendCount = AtomicLong()
    private val droppedCount = AtomicLong()
    private val errorCount = AtomicLong()
    private val peak = AtomicInteger()
    private val diagnosticsLock = Any()
    private var ageCount = 0L
    private var ageSumNs = 0L
    private var ageMinNs = Long.MAX_VALUE
    private var ageMaxNs = Long.MIN_VALUE
    private var diagnosticTimestampFrame: Long? = null
    private var diagnosticReadFrames = 0L
    private var effectFrames = 0L
    private var effectBatches = 0L
    private var batchMin = Int.MAX_VALUE
    private var batchMax = 0
    private var intervalCount = 0L
    private var intervalSumNs = 0L
    private var intervalMinNs = Long.MAX_VALUE
    private var intervalMaxNs = 0L
    private var effectDroppedFrames: Long? = null
    private var effectDroppedBatches: Long? = null
    private var effectActualDelayMs = 0
    private var timelineResets = 0L
    @Volatile private var localDelayMs = 0
    @Volatile private var running = true
    @Volatile private var latencyUs = 50_000
    @Volatile private var timestampSource = "read-fallback"
    @Volatile private var lastError = "none"
    @Volatile private var stage = "arguments"
    private var closed = false
    private var channel: DatagramChannel? = null
    private var capture: PlaybackCapture? = null
    private var effect: EffectSource? = null
    @Volatile private var calibration: AcousticCalibration? = null

    @JvmStatic private external fun installTerminationHandler(): Int
    @JvmStatic private external fun waitForTermination(): Int

    @JvmStatic
    fun main(args: Array<String>) {
        var exitCode = 0
        try {
            var excludeUid: Int? = null
            var name = Build.MODEL
            var mode = "effect"
            var index = 0
            while (index < args.size) {
                val option = args[index++]
                require(index < args.size) { "Missing value for $option" }
                val value = args[index++]
                when (option) {
                    "--exclude-uid" -> excludeUid = value.toInt()
                    "--latency-us" -> latencyUs = value.toInt()
                    "--name" -> name = value
                    "--mode" -> mode = value
                    "--local-delay-ms" -> localDelayMs = value.toInt()
                    else -> error("Unknown option $option")
                }
            }
            val appUid = requireNotNull(excludeUid) { "--exclude-uid is required" }
            require(mode in arrayOf("effect", "intercept", "dup")) { "--mode must be effect, intercept or dup" }
            require(localDelayMs >= 0) { "Local delay must be nonnegative" }
            check(Process.myUid() == 0) { "CaptureMain must be run as root (uid=${Process.myUid()})" }
            stage = "signal_handler"
            val apk = System.getProperty("java.class.path")!!.substringBefore(File.pathSeparator)
            val extractedLibrary = File(File(apk).parentFile, "lib/arm64/libunison_capture.so")
            val library = System.getProperty("unison.capture.library")
                ?: extractedLibrary.takeIf { it.isFile }?.absolutePath
                ?: "$apk!/lib/${Build.SUPPORTED_ABIS.first()}/libunison_capture.so"
            System.load(library)
            val signalStatus = installTerminationHandler()
            check(signalStatus == 0) { "Cannot install SIGTERM handler: errno=${-signalStatus}" }
            Runtime.getRuntime().addShutdownHook(Thread({ close("shutdown") }, "source-shutdown"))
            println("PROCESS pid=${Process.myPid()}")
            thread(name = "source-signal", isDaemon = true) {
                val signal = waitForTermination()
                if (signal < 0) reportError("signal_wait=$signal")
                close("signal=$signal")
                exitProcess(if (signal < 0) 1 else 0)
            }
            // su 的 stdin 与 App 保持连接；App 消失或 stop() 关闭管道都会触发清理。
            thread(name = "source-stdin", isDaemon = true) {
                runCatching {
                    System.`in`.bufferedReader().forEachLine { line ->
                        if (line == "CALIBRATE") startCalibration()
                        if (line.startsWith("LOCAL_DELAY ")) {
                            runCatching {
                                val ms = line.substringAfter(' ').toInt()
                                require(ms >= 0)
                                synchronized(lifecycle) {
                                    check(calibration?.isRunning != true) { "校准期间不能调整延迟" }
                                    if (!closed) { effect?.setLocalDelay(ms); localDelayMs = ms }
                                }
                                println("INFO local_delay_ms=$ms")
                            }.onFailure { reportError("local_delay=${describe(it)}") }
                        }
                    }
                }
                close("stdin_closed")
                exitProcess(0)
            }
            synchronized(lifecycle) {
                if (closed) return
                stage = "udp_bind"
                channel = DatagramChannel.open().apply {
                    configureBlocking(false)
                    socket().broadcast = true
                    bind(InetSocketAddress(SOURCE_PORT))
                }
                if (mode == "effect") {
                    stage = "audio_effect"
                    val source = EffectSource()
                    effect = source
                    source.start(appUid, localDelayMs)
                } else {
                    stage = "audio_policy"
                    val playback = PlaybackCapture()
                    capture = playback
                    playback.start(appUid, mode == "dup")
                }
            }
            val udp = checkNotNull(channel)
            val record = capture?.recorder
            val nameBytes = name.toByteArray(Charsets.UTF_8)
            require(nameBytes.size <= 65535) { "Device name does not fit protocol nameLen" }
            val beacon = message(1, 4 + nameBytes.size).apply {
                putShort(SOURCE_PORT.toShort()).putShort(nameBytes.size.toShort()).put(nameBytes)
            }
            thread(name = "source-control", isDaemon = true) {
                try {
                    receiveControl(udp)
                } catch (error: Throwable) {
                    if (running) fatal("udp_control", error)
                }
            }
            thread(name = "source-status", isDaemon = true) {
                try {
                    while (running) {
                        val now = System.nanoTime()
                        for ((subscriber, subscribedNs) in subscribers.entries) {
                            if (now - subscribedNs >= SUBSCRIBE_TIMEOUT_NS) subscribers.remove(subscriber, subscribedNs)
                        }
                        broadcast(udp, beacon)
                        val effectStatus = effect?.status().orEmpty()
                        val diagnostics = synchronized(diagnosticsLock) {
                            val ages = if (ageCount == 0L) "n/a" else String.format(Locale.ROOT, "%.2f/%.2f/%.2f",
                                ageMinNs / 1_000_000.0, ageSumNs / ageCount / 1_000_000.0, ageMaxNs / 1_000_000.0)
                            val frameLead = diagnosticTimestampFrame?.minus(diagnosticReadFrames)
                            ageCount = 0
                            ageSumNs = 0
                            ageMinNs = Long.MAX_VALUE
                            ageMaxNs = Long.MIN_VALUE
                            val effectStats = if (mode == "effect") {
                                val batches = if (effectBatches == 0L) "n/a" else "$batchMin/${effectFrames / effectBatches}/$batchMax"
                                val intervals = if (intervalCount == 0L) "n/a" else String.format(Locale.ROOT, "%.2f/%.2f/%.2f",
                                    intervalMinNs / 1_000_000.0, intervalSumNs / intervalCount / 1_000_000.0, intervalMaxNs / 1_000_000.0)
                                val text = "effect_frames/s=$effectFrames batch_frames_min_avg_max=$batches " +
                                    "call_interval_ms_min_avg_max=$intervals effect_dropped_frames=${effectDroppedFrames ?: "n/a"} " +
                                    "effect_dropped_batches=${effectDroppedBatches ?: "n/a"} local_delay_ms=$effectActualDelayMs $effectStatus " +
                                    "timeline_resets=$timelineResets "
                                effectFrames = 0; effectBatches = 0; batchMin = Int.MAX_VALUE; batchMax = 0
                                intervalCount = 0; intervalSumNs = 0; intervalMinNs = Long.MAX_VALUE; intervalMaxNs = 0
                                text
                            } else ""
                            effectStats + "capture_age_ms_min_avg_max=$ages buffer_frames=${record?.bufferSizeInFrames ?: 0} " +
                                "ts_frame=${diagnosticTimestampFrame ?: "n/a"} read_frames=$diagnosticReadFrames " +
                                "ts_ahead_frames=${frameLead ?: "n/a"}"
                        }
                        println("STATUS subscribers=${subscribers.size} packets/s=${packetCount.getAndSet(0)} " +
                            "sent/s=${sendCount.getAndSet(0)} dropped=${droppedCount.get()} " +
                            "subscribe/s=${subscribeCount.getAndSet(0)} peers=[${subscribers.keys.joinToString(",")}] " +
                            "timestamp=$timestampSource latency_us=$latencyUs " +
                            "$diagnostics " +
                            "peak=${peak.getAndSet(0)} errors=${errorCount.get()} last_error=$lastError")
                        Thread.sleep(1000)
                    }
                } catch (error: Throwable) {
                    if (running) fatal("status", error)
                }
            }
            println("READY pid=${Process.myPid()} mode=$mode rate=$SAMPLE_RATE channels=2 frames=$FRAMES " +
                "latency_us=$latencyUs local_delay_ms=$localDelayMs buffer_frames=${record?.bufferSizeInFrames ?: 0}")
            stage = if (mode == "effect") "effect_read" else "audio_read"
            if (mode == "effect") captureEffect(checkNotNull(effect), udp) else captureAudio(checkNotNull(record), udp)
        } catch (error: Throwable) {
            if (running) {
                reportError("stage=$stage ${describe(error)}")
                println("FATAL stage=$stage error=${describe(error)}")
                error.printStackTrace(System.out)
                exitCode = 1
            }
        } finally {
            close("main_exit")
        }
        exitProcess(exitCode)
    }

    private fun captureAudio(record: AudioRecord, udp: DatagramChannel) {
        Process.setThreadPriority(Process.THREAD_PRIORITY_AUDIO)
        val data = message(5, 20 + PCM_BYTES)
        data.position(20)
        data.putInt(SAMPLE_RATE).put(2.toByte()).put(1.toByte()).putShort(FRAMES.toShort())
        val bytes = data.array()
        val timestamp = AudioTimestamp()
        var firstFrame = 0L
        var sequence = 0
        var originNs: Long? = null
        var calibrated = false
        var lastTimestampFrame = -1L
        while (running) {
            var read = 0
            while (running && read < PCM_BYTES) {
                val result = record.read(bytes, AUDIO_HEADER + read, PCM_BYTES - read, AudioRecord.READ_BLOCKING)
                if (!running) return
                check(result > 0) { "AudioRecord.read returned $result" }
                read += result
            }
            if (!running) return
            val readNs = System.nanoTime()
            val result = record.getTimestamp(timestamp, AudioTimestamp.TIMEBASE_MONOTONIC)
            if (result == AudioRecord.SUCCESS && timestamp.nanoTime > 0 && timestamp.framePosition > 0) {
                val measuredOrigin = timestamp.nanoTime - framesToNs(timestamp.framePosition)
                // 平滑帧零点，保持每包严格按 240 帧前进；同一硬件时标不重复加权。
                if (!calibrated) {
                    originNs = measuredOrigin
                    calibrated = true
                } else if (timestamp.framePosition != lastTimestampFrame) {
                    val previousOrigin = checkNotNull(originNs)
                    originNs = previousOrigin + (measuredOrigin - previousOrigin) / 16
                }
                lastTimestampFrame = timestamp.framePosition
                timestampSource = "monotonic"
            } else {
                // 首次读取仅锚定一次，之后按帧数推进，不把缓冲容量当成排队时长。
                if (originNs == null) originNs = readNs - framesToNs(firstFrame + FRAMES)
                val estimate = if (calibrated) "last-calibration" else "frame-anchor"
                timestampSource = "read-fallback($result,$estimate)"
            }
            val captureNs = checkNotNull(originNs) + framesToNs(firstFrame)
            synchronized(diagnosticsLock) {
                val ageNs = readNs - captureNs
                ageCount++
                ageSumNs += ageNs
                ageMinNs = minOf(ageMinNs, ageNs)
                ageMaxNs = maxOf(ageMaxNs, ageNs)
                if (result == AudioRecord.SUCCESS) diagnosticTimestampFrame = timestamp.framePosition
                // 与刚完成读取的包末尾比较；正值表示时间戳帧位置领先已读位置。
                diagnosticReadFrames = firstFrame + FRAMES
            }
            data.putInt(8, sequence++)
            data.putLong(12, captureNs / 1000 + latencyUs)
            publishAudio(udp, data)
            firstFrame += FRAMES
        }
    }

    private fun captureEffect(source: EffectSource, udp: DatagramChannel) {
        Process.setThreadPriority(Process.THREAD_PRIORITY_AUDIO)
        val data = message(5, 20 + PCM_BYTES).apply {
            position(20)
            putInt(SAMPLE_RATE).put(2.toByte()).put(1.toByte()).putShort(FRAMES.toShort())
        }
        class Chunk(var startNs: Long, val samples: FloatArray) {
            val frames get() = samples.size / 2
            val endNs get() = startNs + framesToNs(frames.toLong())
        }
        class Stream(val id: Long, var originNs: Long) {
            var previousCallNs = 0L
            var previousFrame = 0L
            var previousBatch = 0
            var expectedFrame = 0L
            var droppedFrames = 0L
            var droppedBatches = 0L
            val chunks = ArrayDeque<Chunk>()
        }
        val streams = mutableMapOf<Int, Stream>()
        val mixed = FloatArray(FRAMES * 2)
        var cursorNs: Long? = null
        var sequence = 0
        timestampSource = "effect-session-clock"
        while (running) {
            val raw = source.read()
            val active = source.activeSessions()
            streams.keys.retainAll(active)
            if (raw != null) {
                val batch = ByteBuffer.wrap(raw).order(ByteOrder.LITTLE_ENDIAN)
                check(raw.size >= 64 && batch.int == 0x31585455) { "Invalid effect tap header" }
                val rate = batch.int
                val frames = batch.int
                val io = batch.int
                val id = batch.long
                val firstFrame = batch.long
                val callNs = batch.long
                val droppedFrames = batch.long
                val droppedBatches = batch.long
                val actualDelay = batch.int
                val session = batch.int
                check(frames > 0 && raw.size.toLong() == 64L + frames.toLong() * 8) { "Invalid effect batch size" }
                check(rate == SAMPLE_RATE) { "Effect tap rate=$rate; UDP prototype requires $SAMPLE_RATE" }
                if (source.acceptStream(session, io)) {
                    val measuredOrigin = callNs - framesToNs(firstFrame)
                    var stream = streams[session]
                    if (stream == null || stream.id != id) {
                        if (stream != null) { sequence += 2; if (streams.size == 1) cursorNs = null }
                        stream = Stream(id, measuredOrigin)
                        streams[session] = stream
                        println("INFO effect_stream session=$session io=$io stream=$id rate=$rate")
                    } else {
                        val elapsedNs = callNs - stream.previousCallNs
                        val advancedFrames = firstFrame - stream.previousFrame
                        val residualNs = elapsedNs - framesToNs(advancedFrames)
                        val toleranceNs = framesToNs(maxOf(stream.previousBatch, frames, FRAMES).toLong())
                        if (advancedFrames <= 0 || elapsedNs <= 0 || abs(residualNs) > toleranceNs) {
                            stream.originNs = measuredOrigin
                            stream.chunks.clear()
                            if (streams.size == 1) cursorNs = null
                            sequence += 2
                            synchronized(diagnosticsLock) { timelineResets++ }
                            println("INFO effect_timeline_reset session=$session residual_ms=${residualNs / 1_000_000.0} io=$io")
                        } else {
                            val correction = (measuredOrigin - stream.originNs) / 16
                            stream.originNs += correction
                            // 同一流尚未发出的批次共用当前零点，避免平滑后批边界重叠被重复相加。
                            for (chunk in stream.chunks) chunk.startNs += correction
                        }
                        if (firstFrame != stream.expectedFrame) {
                            sequence += 2
                            stream.chunks.clear()
                            if (streams.size == 1) cursorNs = null
                        }
                    }
                    synchronized(diagnosticsLock) {
                        effectFrames += frames; effectBatches++
                        batchMin = minOf(batchMin, frames); batchMax = maxOf(batchMax, frames)
                        if (stream.previousCallNs != 0L) {
                            val interval = callNs - stream.previousCallNs
                            intervalCount++; intervalSumNs += interval
                            intervalMinNs = minOf(intervalMinNs, interval); intervalMaxNs = maxOf(intervalMaxNs, interval)
                        }
                        effectActualDelayMs = actualDelay
                        diagnosticReadFrames += frames
                    }
                    stream.previousCallNs = callNs; stream.previousFrame = firstFrame; stream.previousBatch = frames
                    stream.expectedFrame = firstFrame + frames
                    stream.droppedFrames = droppedFrames; stream.droppedBatches = droppedBatches
                    val samples = FloatArray(frames * 2)
                    batch.asFloatBuffer().get(samples)
                    stream.chunks.addLast(Chunk(stream.originNs + framesToNs(firstFrame), samples))
                }
            }
            synchronized(diagnosticsLock) {
                effectDroppedFrames = streams.values.sumOf { it.droppedFrames }
                effectDroppedBatches = streams.values.sumOf { it.droppedBatches }
            }
            if (streams.isEmpty()) {
                if (cursorNs != null) sequence += 2
                cursorNs = null
                continue
            }
            while (running) {
                val chunks = streams.values.flatMap { it.chunks }
                val firstNs = chunks.minOfOrNull { it.startNs } ?: break
                var startNs = cursorNs ?: firstNs
                if (firstNs > startNs + framesToNs(FRAMES.toLong())) {
                    // 空窗不延长旧包；序号不相邻，使接收端按正常包长结束旧包。
                    sequence += 2
                    startNs = firstNs
                }
                val endNs = startNs + framesToNs(FRAMES.toLong())
                if (chunks.maxOf { it.endNs } + 10_000 < endNs) break
                // 多会话批次错开到达时等到该量子末端，避免先到的流抢先发出。
                // 单会话仍在收到完整量子时立即发送。
                if (active.any { (streams[it]?.chunks?.lastOrNull()?.endNs ?: Long.MIN_VALUE) + 10_000 < endNs }
                    && System.nanoTime() < endNs) break
                mixed.fill(0f)
                for (chunk in chunks) {
                    val offset = Math.round((chunk.startNs - startNs) * SAMPLE_RATE / 1_000_000_000.0).toInt()
                    val destination = maxOf(0, offset)
                    val sourceFrame = maxOf(0, -offset)
                    val count = minOf(FRAMES - destination, chunk.frames - sourceFrame)
                    for (frame in 0 until count) for (channel in 0..1) {
                        mixed[(destination + frame) * 2 + channel] += chunk.samples[(sourceFrame + frame) * 2 + channel]
                    }
                }
                val currentCalibration = calibration
                currentCalibration?.onTap(startNs, mixed)
                val silence = currentCalibration?.networkMuted == true
                for (sample in mixed.indices) {
                    val pcm = if (silence) 0
                        else (mixed[sample] * 32768f).toInt().coerceIn(-32768, 32767)
                    data.putShort(AUDIO_HEADER + sample * 2, pcm.toShort())
                }
                data.putInt(8, sequence++)
                data.putLong(12, startNs / 1000 + latencyUs)
                synchronized(diagnosticsLock) {
                    val age = System.nanoTime() - startNs
                    ageCount++; ageSumNs += age
                    ageMinNs = minOf(ageMinNs, age); ageMaxNs = maxOf(ageMaxNs, age)
                }
                publishAudio(udp, data)
                cursorNs = endNs
                for (stream in streams.values) while (stream.chunks.firstOrNull()?.let { it.endNs <= endNs + 10_000 } == true) {
                    stream.chunks.removeFirst()
                }
            }
        }
    }

    private fun publishAudio(udp: DatagramChannel, data: ByteBuffer) {
        var packetPeak = 0
        for (offset in AUDIO_HEADER until data.capacity() step 2) packetPeak = maxOf(packetPeak, abs(data.getShort(offset).toInt()))
        peak.accumulateAndGet(packetPeak) { previous, current -> maxOf(previous, current) }
        val now = System.nanoTime()
        for ((subscriber, subscribedNs) in subscribers.entries) {
            if (now - subscribedNs >= SUBSCRIBE_TIMEOUT_NS) { subscribers.remove(subscriber, subscribedNs); continue }
            if (send(udp, data, subscriber, "audio_send")) sendCount.incrementAndGet()
        }
        packetCount.incrementAndGet()
    }

    private fun receiveControl(udp: DatagramChannel) = Selector.open().use { selector ->
        udp.register(selector, SelectionKey.OP_READ)
        val data = ByteBuffer.allocate(65507).order(ByteOrder.LITTLE_ENDIAN)
        while (running) {
            if (selector.select(250) == 0) continue
            selector.selectedKeys().clear()
            data.clear()
            val sender = udp.receive(data) as InetSocketAddress? ?: continue
            val receivedUs = System.nanoTime() / 1000
            data.flip()
            if (data.remaining() < 8) continue
            if (data.int != MAGIC || data.get().toInt() != 1) continue
            val type = data.get().toInt()
            data.short
            when (type) {
                2 -> {
                    if (data.remaining() < 10) continue
                    data.long // receiverId；订阅按源地址和端口识别。
                    val nameLength = data.short.toInt() and 0xffff
                    if (data.remaining() >= nameLength) {
                        subscribers[sender] = System.nanoTime()
                        subscribeCount.incrementAndGet()
                    }
                }
                3 -> {
                    if (data.remaining() < 12) continue
                    val pingId = data.int
                    val t1 = data.long
                    val pong = message(4, 28).apply {
                        putInt(pingId).putLong(t1).putLong(receivedUs).putLong(System.nanoTime() / 1000)
                    }
                    send(udp, pong, sender, "pong_send")
                }
                6 -> subscribers.remove(sender)
                7 -> if (sender.address.hostAddress == "127.0.0.1" && data.remaining() >= 4 && calibration?.isRunning != true) latencyUs = data.int
            }
        }
    }

    private fun broadcast(udp: DatagramChannel, beacon: ByteBuffer) {
        val addresses = linkedSetOf(InetAddress.getByName("255.255.255.255"))
        try {
            val interfaces = NetworkInterface.getNetworkInterfaces()
            if (interfaces != null) {
                for (network in Collections.list(interfaces)) {
                    if (network.isUp && !network.isLoopback) {
                        network.interfaceAddresses.mapNotNullTo(addresses) { it.broadcast }
                    }
                }
            }
        } catch (error: Exception) {
            if (running) reportError("broadcast_interfaces=${describe(error)}")
        }
        for (address in addresses) {
            send(udp, beacon, InetSocketAddress(address, BEACON_PORT), "beacon_send")
        }
    }

    private fun send(udp: DatagramChannel, data: ByteBuffer, destination: InetSocketAddress, operation: String): Boolean {
        try {
            data.rewind()
            // 非阻塞 send 返回 0 时直接丢包，不等待发送缓冲腾出空间。
            if (udp.send(data, destination) == data.limit()) return true
        } catch (error: Exception) {
            if (running) reportError("$operation=${describe(error)}")
        }
        if (running) droppedCount.incrementAndGet()
        return false
    }

    private fun close(reason: String) = synchronized(lifecycle) {
        if (closed) return@synchronized
        closed = true
        running = false
        calibration?.cancel()
        // 先恢复本机路由，再关闭网络；不依赖阻塞中的录音线程主动返回。
        val restored = capture?.close() ?: true
        runCatching { effect?.close() }.onFailure { println("ERROR release_effect=${describe(it)}") }
        channel?.let { udp ->
            val bye = message(6, 0)
            for (subscriber in subscribers.keys) {
                send(udp, bye, subscriber, "bye_send")
            }
            udp.close()
        }
        println("STOPPED reason=$reason policy=${if (restored) "unregistered" else "unregister_failed"}")
    }

    private fun startCalibration() = synchronized(lifecycle) {
        if (closed || calibration?.isRunning == true) return@synchronized
        val source = effect
        if (source == null) {
            println("CALIBRATION " + org.json.JSONObject().put("state", "error").put("message", "请先启动 effect 音源"))
            return@synchronized
        }
        calibration = AcousticCalibration(source, latencyUs, localDelayMs,
            hasSubscribers = { subscribers.values.any { System.nanoTime() - it < SUBSCRIBE_TIMEOUT_NS } },
            applySettings = { target, local ->
                // 不获取 lifecycle；关闭线程会持 lifecycle 等待校准的 control 锁。
                check(running) { "音源已停止" }
                source.setLocalDelay(local)
                localDelayMs = local
                latencyUs = target
            }).also { it.start() }
    }

    private fun fatal(failedStage: String, error: Throwable) {
        reportError("stage=$failedStage ${describe(error)}")
        println("FATAL stage=$failedStage error=${describe(error)}")
        error.printStackTrace(System.out)
        close("fatal:$failedStage")
        exitProcess(1)
    }

    private fun reportError(message: String) {
        errorCount.incrementAndGet()
        lastError = message.replace('\n', ' ').replace('\r', ' ')
    }

    private fun describe(error: Throwable): String {
        val cause = error.cause ?: error
        return "${cause.javaClass.simpleName}:${cause.message}"
    }

    private fun framesToNs(frames: Long) = frames / SAMPLE_RATE * 1_000_000_000L +
        frames % SAMPLE_RATE * 1_000_000_000L / SAMPLE_RATE

    private fun message(type: Int, payload: Int): ByteBuffer = ByteBuffer.allocate(8 + payload)
        .order(ByteOrder.LITTLE_ENDIAN).apply {
            putInt(MAGIC).put(1.toByte()).put(type.toByte()).putShort(0.toShort())
        }
}
