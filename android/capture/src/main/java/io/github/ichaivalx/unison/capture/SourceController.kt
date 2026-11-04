package io.github.ichaivalx.unison.capture

import android.content.Context
import android.os.Build
import java.io.File
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.concurrent.thread

object SourceController {
    @Volatile private var process: java.lang.Process? = null
    @Volatile private var ready = false
    @Volatile private var rootPid = 0
    @Volatile private var output: ((String) -> Unit)? = null
    @Volatile private var localDelayMs = 0
    private val commands = Executors.newSingleThreadExecutor { task ->
        Thread(task, "source-commands").apply { isDaemon = true }
    }

    /** 用 su 启动音源进程；su 不可用返回 false。onLine 在后台线程收到音源进程的每行输出。 */
    @Synchronized
    fun start(context: Context, latencyMs: Int, onLine: (String) -> Unit): Boolean {
        if (isRunning) return true
        stop()
        output = onLine
        val apk = context.applicationInfo.sourceDir
        val extracted = File(context.applicationInfo.nativeLibraryDir, "libunison_capture.so")
        val library = if (extracted.isFile) extracted.absolutePath
            else "$apk!/lib/${Build.SUPPORTED_ABIS.first()}/libunison_capture.so"
        val latencyUs = try {
            Math.multiplyExact(latencyMs, 1000)
        } catch (error: ArithmeticException) {
            emit("ERROR latency does not fit SET_LATENCY i32: $latencyMs ms")
            return false
        }
        val command = "CLASSPATH=${quote(apk)} exec app_process " +
            "${quote("-Dunison.capture.library=$library")} /system/bin " +
            "io.github.ichaivalx.unison.capture.CaptureMain " +
            "--exclude-uid ${context.applicationInfo.uid} --latency-us $latencyUs " +
            "--name ${quote(Build.MODEL)} --mode effect --local-delay-ms $localDelayMs"
        val child = try {
            ProcessBuilder("su", "-c", command).redirectErrorStream(true).start()
        } catch (error: Exception) {
            emit("ERROR su unavailable: ${error.message}")
            return false
        }
        process = child
        rootPid = 0
        ready = false
        val startup = CountDownLatch(1)
        val acknowledged = AtomicBoolean(false)
        thread(name = "source-output", isDaemon = true) {
            try {
                child.inputStream.bufferedReader().useLines { lines ->
                    lines.forEach { line ->
                        if (process === child && line.startsWith("PROCESS pid=")) {
                            rootPid = line.substringAfter("PROCESS pid=").toIntOrNull() ?: 0
                        }
                        if (process === child && line.startsWith("READY ")) {
                            acknowledged.set(true)
                            ready = true
                            startup.countDown()
                        }
                        runCatching { onLine(line) }
                    }
                }
            } catch (error: Exception) {
                if (ready) runCatching { onLine("ERROR source output: ${error.message}") }
            } finally {
                startup.countDown()
                // 不取 start/stop 的锁，避免等待子进程退出时互相阻塞。
                if (process === child) ready = false
            }
        }
        val started = try {
            // 包含首次 root 授权弹窗的等待时间；超时也要关闭 stdin 撤销拦截。
            startup.await(30, TimeUnit.SECONDS) && acknowledged.get() && ready && child.isAlive
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
            false
        }
        if (!started) {
            emit("ERROR source startup failed or timed out; check root permission and source output")
            stop()
        } else {
            // 启动命令只是快照；授权/启动等待期间 UI 仍可更新期望值。
            setLocalDelay(localDelayMs)
        }
        return started
    }

    @Synchronized
    fun stop() {
        val child = process ?: return
        ready = false
        runCatching { child.outputStream.close() }
        try {
            if (!child.waitFor(3, TimeUnit.SECONDS)) {
                // su 本身可能是转发进程；使用音源报告的 PID 终止真正的 app_process。
                if (rootPid > 0) signalRoot(rootPid, "TERM") else child.destroy()
                if (!child.waitFor(2, TimeUnit.SECONDS)) {
                    if (rootPid > 0) signalRoot(rootPid, "KILL")
                    child.destroyForcibly()
                }
            }
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
            child.destroy()
        }
        process = null
        rootPid = 0
    }

    /** 运行中调整目标延迟。 */
    fun setLatency(latencyMs: Int) {
        val current = process ?: return
        commands.execute {
            if (process !== current || !isRunning) return@execute
            try {
                val bytes = ByteBuffer.allocate(12).order(ByteOrder.LITTLE_ENDIAN)
                    .putInt(0x4E534E55).put(1.toByte()).put(7.toByte()).putShort(0.toShort())
                    .putInt(Math.multiplyExact(latencyMs, 1000)).array()
                DatagramSocket().use { udp ->
                    udp.send(DatagramPacket(bytes, bytes.size, InetAddress.getByName("127.0.0.1"), 47800))
                }
            } catch (error: Exception) {
                runCatching { output?.invoke("ERROR set_latency: ${error.message}") }
            }
        }
    }

    val isRunning: Boolean get() = ready && process?.isAlive == true

    /** 本机效果直通的延迟，不改变网络目标延迟。 */
    fun setLocalDelay(ms: Int) {
        require(ms >= 0) { "本机延迟不能为负数" }
        localDelayMs = ms
        val current = process ?: return
        commands.execute {
            if (process !== current || !isRunning) return@execute
            runCatching {
                current.outputStream.write("LOCAL_DELAY $localDelayMs\n".toByteArray(Charsets.UTF_8))
                current.outputStream.flush()
            }.onFailure { if (isRunning) output?.invoke("ERROR local_delay: ${it.message}") }
        }
    }

    private fun signalRoot(pid: Int, signal: String) {
        runCatching {
            val kill = ProcessBuilder("su", "-c", "kill -$signal $pid").start()
            if (!kill.waitFor(2, TimeUnit.SECONDS)) kill.destroy()
        }.onFailure { emit("ERROR terminate source: ${it.message}") }
    }

    private fun emit(line: String) {
        val callback = output
        thread(name = "source-output-error", isDaemon = true) { runCatching { callback?.invoke(line) } }
    }

    private fun quote(value: String) = "'" + value.replace("'", "'\\''") + "'"
}
