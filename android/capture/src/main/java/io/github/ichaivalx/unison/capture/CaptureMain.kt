package io.github.ichaivalx.unison.capture

import android.media.AudioRecord
import android.media.AudioTimestamp
import android.os.Build
import android.os.Process
import java.io.File
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.NetworkInterface
import java.net.SocketTimeoutException
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.Collections
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
    private val sendCount = AtomicLong()
    private val errorCount = AtomicLong()
    private val peak = AtomicInteger()
    @Volatile private var running = true
    @Volatile private var latencyUs = 50_000
    @Volatile private var timestampSource = "read-fallback"
    @Volatile private var lastError = "none"
    @Volatile private var stage = "arguments"
    private var closed = false
    private var socket: DatagramSocket? = null
    private var capture: PlaybackCapture? = null

    @JvmStatic private external fun installTerminationHandler(): Int
    @JvmStatic private external fun waitForTermination(): Int

    @JvmStatic
    fun main(args: Array<String>) {
        var exitCode = 0
        try {
            var excludeUid: Int? = null
            var name = Build.MODEL
            var mode = "intercept"
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
                    else -> error("Unknown option $option")
                }
            }
            val appUid = requireNotNull(excludeUid) { "--exclude-uid is required" }
            require(mode == "intercept" || mode == "dup") { "--mode must be intercept or dup" }
            check(Process.myUid() == 0) { "CaptureMain must be run as root (uid=${Process.myUid()})" }
            stage = "signal_handler"
            val apk = System.getProperty("java.class.path")!!.substringBefore(File.pathSeparator)
            val library = System.getProperty("unison.capture.library")
                ?: "$apk!/lib/${Build.SUPPORTED_ABIS.first()}/libunison_capture.so"
            System.load(library)
            check(installTerminationHandler() == 0) { "Cannot install SIGTERM handler" }
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
                runCatching { while (System.`in`.read() != -1) { /* 等待 EOF */ } }
                close("stdin_closed")
                exitProcess(0)
            }
            synchronized(lifecycle) {
                if (closed) return
                stage = "udp_bind"
                socket = DatagramSocket(null).apply {
                    broadcast = true
                    soTimeout = 250
                    bind(InetSocketAddress(SOURCE_PORT))
                }
                stage = "audio_policy"
                val playback = PlaybackCapture()
                capture = playback
                playback.start(appUid, mode == "dup")
            }
            val udp = checkNotNull(socket)
            val record = checkNotNull(capture?.recorder)
            val nameBytes = name.toByteArray(Charsets.UTF_8)
            require(nameBytes.size <= 65535) { "Device name does not fit protocol nameLen" }
            val beacon = message(1, 4 + nameBytes.size).apply {
                putShort(SOURCE_PORT.toShort()).putShort(nameBytes.size.toShort()).put(nameBytes)
            }.array()
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
                        println("STATUS subscribers=${subscribers.size} packets/s=${packetCount.getAndSet(0)} " +
                            "sent/s=${sendCount.getAndSet(0)} timestamp=$timestampSource latency_us=$latencyUs " +
                            "peak=${peak.getAndSet(0)} errors=${errorCount.get()} last_error=$lastError")
                        Thread.sleep(1000)
                    }
                } catch (error: Throwable) {
                    if (running) fatal("status", error)
                }
            }
            println("READY pid=${Process.myPid()} mode=$mode rate=$SAMPLE_RATE channels=2 frames=$FRAMES " +
                "latency_us=$latencyUs buffer_frames=${record.bufferSizeInFrames}")
            stage = "audio_read"
            captureAudio(record, udp)
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

    private fun captureAudio(record: AudioRecord, udp: DatagramSocket) {
        Process.setThreadPriority(Process.THREAD_PRIORITY_AUDIO)
        val data = message(5, 20 + PCM_BYTES)
        data.position(20)
        data.putInt(SAMPLE_RATE).put(2.toByte()).put(1.toByte()).putShort(FRAMES.toShort())
        val bytes = data.array()
        val datagram = DatagramPacket(bytes, bytes.size)
        val timestamp = AudioTimestamp()
        var firstFrame = 0L
        var sequence = 0
        var originNs: Long? = null
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
            val captureNs: Long
            if (result == AudioRecord.SUCCESS && timestamp.nanoTime > 0 && timestamp.framePosition > 0) {
                val measuredOrigin = timestamp.nanoTime - framesToNs(timestamp.framePosition)
                // 平滑帧零点，保持每包严格按 240 帧前进；同一硬件时标不重复加权。
                if (originNs == null) originNs = measuredOrigin
                else if (timestamp.framePosition != lastTimestampFrame) originNs += (measuredOrigin - originNs) / 16
                lastTimestampFrame = timestamp.framePosition
                captureNs = originNs + framesToNs(firstFrame)
                timestampSource = "monotonic"
            } else {
                // 优先用最近校准的帧零点估计排队时长；启动时只能用缓冲容量估算。
                val bufferedNs = originNs?.let { readNs - it - framesToNs(firstFrame) }
                    ?: framesToNs(record.bufferSizeInFrames.toLong())
                captureNs = readNs - bufferedNs
                val estimate = if (originNs == null) "buffer-estimate" else "last-calibration"
                timestampSource = "read-fallback($result,$estimate)"
            }
            data.putInt(8, sequence++)
            data.putLong(12, captureNs / 1000 + latencyUs)
            var packetPeak = 0
            for (offset in AUDIO_HEADER until bytes.size step 2) {
                packetPeak = maxOf(packetPeak, abs(data.getShort(offset).toInt()))
            }
            peak.accumulateAndGet(packetPeak) { previous, current -> maxOf(previous, current) }
            val now = System.nanoTime()
            for ((subscriber, subscribedNs) in subscribers.entries) {
                if (now - subscribedNs >= SUBSCRIBE_TIMEOUT_NS) {
                    subscribers.remove(subscriber, subscribedNs)
                    continue
                }
                datagram.socketAddress = subscriber
                try {
                    udp.send(datagram)
                    sendCount.incrementAndGet()
                } catch (error: Exception) {
                    if (running) reportError("audio_send=${describe(error)}")
                }
            }
            packetCount.incrementAndGet()
            firstFrame += FRAMES
        }
    }

    private fun receiveControl(udp: DatagramSocket) {
        val bytes = ByteArray(65507)
        val packet = DatagramPacket(bytes, bytes.size)
        while (running) {
            packet.length = bytes.size
            try {
                udp.receive(packet)
            } catch (_: SocketTimeoutException) {
                continue
            }
            val receivedUs = System.nanoTime() / 1000
            if (packet.length < 8) continue
            val data = ByteBuffer.wrap(bytes, 0, packet.length).order(ByteOrder.LITTLE_ENDIAN)
            if (data.int != MAGIC || data.get().toInt() != 1) continue
            val type = data.get().toInt()
            data.short
            val sender = packet.socketAddress as InetSocketAddress
            when (type) {
                2 -> {
                    if (data.remaining() < 10) continue
                    data.long // receiverId；订阅按源地址和端口识别。
                    val nameLength = data.short.toInt() and 0xffff
                    if (data.remaining() >= nameLength) subscribers[sender] = System.nanoTime()
                }
                3 -> {
                    if (data.remaining() < 12) continue
                    val pingId = data.int
                    val t1 = data.long
                    val pong = message(4, 28).apply {
                        putInt(pingId).putLong(t1).putLong(receivedUs).putLong(System.nanoTime() / 1000)
                    }.array()
                    try {
                        udp.send(DatagramPacket(pong, pong.size, sender))
                    } catch (error: Exception) {
                        if (running) reportError("pong_send=${describe(error)}")
                    }
                }
                6 -> subscribers.remove(sender)
                7 -> if (packet.address.hostAddress == "127.0.0.1" && data.remaining() >= 4) latencyUs = data.int
            }
        }
    }

    private fun broadcast(udp: DatagramSocket, beacon: ByteArray) {
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
            try {
                udp.send(DatagramPacket(beacon, beacon.size, address, BEACON_PORT))
            } catch (error: Exception) {
                if (running) reportError("beacon_send=${describe(error)}")
            }
        }
    }

    private fun close(reason: String) = synchronized(lifecycle) {
        if (closed) return@synchronized
        closed = true
        running = false
        // 先恢复本机路由，再关闭网络；不依赖阻塞中的录音线程主动返回。
        val restored = capture?.close() ?: true
        socket?.let { udp ->
            val bye = message(6, 0).array()
            for (subscriber in subscribers.keys) {
                runCatching { udp.send(DatagramPacket(bye, bye.size, subscriber)) }
            }
            udp.close()
        }
        println("STOPPED reason=$reason policy=${if (restored) "unregistered" else "unregister_failed"}")
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

    private fun framesToNs(frames: Long) = frames * 1_000_000_000L / SAMPLE_RATE

    private fun message(type: Int, payload: Int): ByteBuffer = ByteBuffer.allocate(8 + payload)
        .order(ByteOrder.LITTLE_ENDIAN).apply {
            putInt(MAGIC).put(1.toByte()).put(type.toByte()).putShort(0.toShort())
        }
}
