package io.github.ichaivalx.unison.capture

import android.os.Process
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.NetworkInterface
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.channels.DatagramChannel
import java.nio.channels.SelectionKey
import java.nio.channels.Selector
import java.util.Collections
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import kotlin.concurrent.thread
import kotlin.math.abs

internal class SourceSession(private val excludeUid: Int, @Volatile var latencyUs: Long,
    @Volatile var localDelayUs: Long, private val onFatal: (Throwable) -> Unit) {
    private val MAGIC = 0x4E534E55
    private val SOURCE_PORT = 47800
    private val BEACON_PORT = 47801
    private val SAMPLE_RATE = 48_000
    private val FRAMES = 240
    private val AUDIO_HEADER = 28
    private val PCM_BYTES = FRAMES * 2 * 2
    private val silentPacket by lazy { message(5, 20 + PCM_BYTES) }
    private val SUBSCRIBE_TIMEOUT_NS = 5_000_000_000L
    private val lifecycle = Any()
    private data class Subscriber(val id: Long, val lastNs: Long)
    private val subscribers = ConcurrentHashMap<InetSocketAddress, Subscriber>()
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
    private var timelineResets = 0L
    @Volatile private var running = true
    @Volatile private var lastError = "none"
    @Volatile private var fatalError: String? = null
    private var closed = false
    private var channel: DatagramChannel? = null
    private var effect: EffectSource? = null
    private var captureThread: Thread? = null
    @Volatile private var calibration: AcousticCalibration? = null

    fun start() {
        try {
            channel = DatagramChannel.open().apply { configureBlocking(false); socket().broadcast = true; bind(InetSocketAddress(SOURCE_PORT)) }
            effect = EffectSource().also { it.onSessionsChanged = { RootEvents.emit("source", status()) } }
            checkNotNull(effect).start(excludeUid, localDelayUs)
            val udp = checkNotNull(channel)
            val name = android.os.Build.MODEL.toByteArray(Charsets.UTF_8)
            val beacon = message(1, 4 + name.size).apply { putShort(SOURCE_PORT.toShort()).putShort(name.size.toShort()).put(name) }
            thread(name = "source-control", isDaemon = true) { try { receiveControl(udp) } catch (error: Throwable) { if (running) fatal(error) } }
            thread(name = "source-status", isDaemon = true) {
                try { while (running) {
                    val now = System.nanoTime()
                    for ((peer, sub) in subscribers.entries) if (now - sub.lastNs >= SUBSCRIBE_TIMEOUT_NS) subscribers.remove(peer, sub)
                    broadcast(udp, beacon)
                    RootEvents.emit("source", status())
                    println("STATUS subscribers=${subscribers.size} peers=[${subscribers.keys.joinToString(",")}] latency_us=$latencyUs local_delay_us=$localDelayUs " +
                        "packets/s=${packetCount.getAndSet(0)} sent/s=${sendCount.getAndSet(0)} dropped=${droppedCount.get()} " +
                        "peak=${peak.getAndSet(0)} subscriptions/s=${subscribeCount.getAndSet(0)} errors=${errorCount.get()} " +
                        "${diagnostics()} ${effect?.status()} last_error=$lastError")
                    Thread.sleep(1000)
                } } catch (error: Throwable) { if (running) fatal(error) }
            }
            captureThread = thread(name = "effect-capture", isDaemon = true) { try { captureEffect(checkNotNull(effect), udp) } catch (error: Throwable) { if (running) fatal(error) } }
            RootEvents.emit("source", status())
        } catch (error: Throwable) { close("start_failed"); throw error }
    }

    fun status(): org.json.JSONObject = org.json.JSONObject().put("running", running && !closed)
        .put("latencyUs", latencyUs).put("localDelayUs", localDelayUs).put("sessions", effect?.sessionStatus() ?: org.json.JSONArray())
        .put("receiverIds", org.json.JSONArray(receiverIds())).put("error", fatalError ?: org.json.JSONObject.NULL)

    private fun diagnostics(): String = synchronized(diagnosticsLock) {
        fun ms(ns: Long) = ns / 1_000_000.0
        val age = if (ageCount == 0L) "-" else "${ms(ageMinNs)}/${ms(ageSumNs / ageCount)}/${ms(ageMaxNs)}"
        val batch = if (effectBatches == 0L) "-" else "$batchMin/${effectFrames / effectBatches}/$batchMax"
        val interval = if (intervalCount == 0L) "-" else "${ms(intervalMinNs)}/${ms(intervalSumNs / intervalCount)}/${ms(intervalMaxNs)}"
        val text = "effect_frames/s=$effectFrames batch=$batch call_ms=$interval capture_age_ms=$age " +
            "effect_dropped_frames=$effectDroppedFrames effect_dropped_batches=$effectDroppedBatches timeline_resets=$timelineResets"
        effectFrames = 0; effectBatches = 0; batchMin = Int.MAX_VALUE; batchMax = 0
        intervalCount = 0; intervalSumNs = 0; intervalMinNs = Long.MAX_VALUE; intervalMaxNs = 0
        ageCount = 0; ageSumNs = 0; ageMinNs = Long.MAX_VALUE; ageMaxNs = Long.MIN_VALUE
        text
    }

    fun receiverIds(): List<Long> = subscribers.values.filter { System.nanoTime() - it.lastNs < SUBSCRIBE_TIMEOUT_NS }.map { it.id }.distinct()
    fun setDelay(us: Long) { check(calibration?.isRunning != true) { "校准中" }; check(us >= 0); effect?.setLocalDelay(us); localDelayUs = us; RootEvents.emit("source", status()) }
    fun setLatency(us: Long) { check(calibration?.isRunning != true) { "校准中" }; latencyUs = us; RootEvents.emit("source", status()) }
    fun cancelCalibration() { calibration?.cancel() }
    fun calibrate(ids: List<Long>, bands: List<String>, progress: (org.json.JSONObject) -> Unit,
        complete: (org.json.JSONObject?, Throwable?) -> Unit) {
        check(calibration?.isRunning != true) { "校准已在进行" }
        calibration = AcousticCalibration(checkNotNull(effect), latencyUs, localDelayUs, ids.distinct(), bands.distinct(),
            subscribed = { it in receiverIds() }, progress = progress, complete = complete).also { it.start() }
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
        while (running) {
            val raw = source.read()
            val active = if (calibration?.isRunning == true) setOfNotNull(calibration?.sessionId) else source.activeSessions()
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
                batch.int // 本机延迟的毫秒诊断值；实际设置保留微秒精度。
                val session = batch.int
                check(frames > 0 && raw.size.toLong() == 64L + frames.toLong() * 8) { "Invalid effect batch size" }
                check(rate == SAMPLE_RATE) { "Effect tap rate=$rate; UDP prototype requires $SAMPLE_RATE" }
                if (session in active && source.acceptStream(session, io)) {
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
                for (sample in mixed.indices) {
                    val pcm = (mixed[sample] * 32768f).toInt().coerceIn(-32768, 32767)
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
        val currentCalibration = calibration
        val silent = silentPacket
        silent.position(8); silent.put(data.array(), 8, AUDIO_HEADER - 8)
        for ((subscriber, sub) in subscribers.entries) {
            if (now - sub.lastNs >= SUBSCRIBE_TIMEOUT_NS) { subscribers.remove(subscriber, sub); continue }
            val payload = if (currentCalibration?.isRunning == true && currentCalibration.networkTarget != sub.id) silent else data
            if (send(udp, payload, subscriber, "audio_send")) sendCount.incrementAndGet()
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
                    val receiverId = data.long
                    val nameLength = data.short.toInt() and 0xffff
                    if (data.remaining() >= nameLength) {
                        val previous = subscribers.put(sender, Subscriber(receiverId, System.nanoTime()))
                        if (previous?.id != receiverId) RootEvents.emit("source", status())
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
                6 -> if (subscribers.remove(sender) != null) RootEvents.emit("source", status())
                7 -> if (sender.address.hostAddress == "127.0.0.1" && data.remaining() >= 4 && calibration?.isRunning != true) latencyUs = data.int.toLong()
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

    fun close(reason: String = "stopped") = synchronized(lifecycle) {
        if (closed) return@synchronized
        closed = true
        running = false
        calibration?.cancel()
        // 先恢复本机路由，再关闭网络；不依赖阻塞中的录音线程主动返回。
        runCatching { effect?.close() }.onFailure { println("ERROR release_effect=${describe(it)}") }
        channel?.let { udp ->
            val bye = message(6, 0)
            for (subscriber in subscribers.keys) {
                send(udp, bye, subscriber, "bye_send")
            }
            udp.close()
        }
        if (Thread.currentThread() !== captureThread) runCatching { captureThread?.join(1000) }
        RootEvents.emit("source", status())
        println("STOPPED reason=$reason")
    }

    private fun fatal(error: Throwable) {
        lastError = describe(error)
        fatalError = lastError
        RootEvents.emit("source", status().put("running", false))
        close("fatal")
        onFatal(error)
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
