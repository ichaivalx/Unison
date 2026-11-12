package io.github.ichaivalx.unison.capture

import android.content.Context
import android.os.Build
import android.util.Log
import java.io.File
import java.util.concurrent.CompletableFuture
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong
import org.json.JSONObject
import kotlin.concurrent.thread

object SourceController {
    @Volatile private var process: Process? = null
    @Volatile private var ready = false
    @Volatile private var rootPid = 0
    @Volatile var onEvent: ((String, Any?) -> Unit)? = null
    val isRunning: Boolean get() = ready && process?.isAlive == true
    private val ids = AtomicLong()
    private val pending = ConcurrentHashMap<Long, CompletableFuture<Any?>>()
    @Synchronized fun ensure(context: Context): Boolean {
        if (ready && process?.isAlive == true) return true
        shutdown()
        val apk = context.applicationInfo.sourceDir
        val extracted = File(context.applicationInfo.nativeLibraryDir, "libunison_capture.so")
        val library = if (extracted.isFile) extracted.absolutePath else "$apk!/lib/${Build.SUPPORTED_ABIS.first()}/libunison_capture.so"
        val command = "CLASSPATH=${quote(apk)} exec app_process ${quote("-Dunison.capture.library=$library")} /system/bin " +
            "io.github.ichaivalx.unison.capture.CaptureMain ${context.applicationInfo.uid}"
        val child = try { ProcessBuilder("su", "-c", command).redirectErrorStream(true).start() } catch (_: Exception) { return false }
        process = child
        val started = CountDownLatch(1)
        thread(name = "root-events", isDaemon = true) {
            try {
                child.inputStream.bufferedReader().useLines { lines -> lines.forEach { line ->
                    if (process !== child) return@forEach
                    if (!line.startsWith("{")) { log(line); return@forEach }
                    runCatching {
                        val event = JSONObject(line)
                        when (val type = event.getString("type")) {
                            "ready" -> { rootPid = event.getJSONObject("data").getInt("pid"); ready = true; started.countDown() }
                            "reply" -> pending.remove(event.getLong("id"))?.let { future ->
                                if (!event.isNull("error")) future.completeExceptionally(IllegalStateException(event.getString("error")))
                                else future.complete(event.opt("result").takeUnless { it == JSONObject.NULL })
                            }
                            else -> onEvent?.invoke(type, event.opt("data").takeUnless { it == JSONObject.NULL })
                        }
                    }
                } }
            } finally {
                started.countDown()
                if (process === child) {
                    ready = false
                    pending.values.forEach { it.completeExceptionally(IllegalStateException("Root process exited")) }; pending.clear()
                    onEvent?.invoke("rootExit", null)
                }
            }
        }
        if (!started.await(30, TimeUnit.SECONDS) || !ready) { shutdown(); return false }
        return true
    }
    fun request(method: String, args: JSONObject = JSONObject()): CompletableFuture<Any?> {
        val result = CompletableFuture<Any?>(); val id = ids.incrementAndGet(); pending[id] = result
        try { synchronized(this) {
            check(ready && process?.isAlive == true) { "Root is unavailable" }
            val bytes = (JSONObject().put("id", id).put("method", method).put("args", args).toString() + "\n").toByteArray(Charsets.UTF_8)
            process!!.outputStream.write(bytes); process!!.outputStream.flush()
        } } catch (error: Throwable) { pending.remove(id); result.completeExceptionally(error) }
        return result
    }
    @Synchronized fun shutdown() {
        val child = process; process = null; ready = false
        runCatching { child?.outputStream?.close() }
        if (child != null && !child.waitFor(3, TimeUnit.SECONDS)) {
            if (rootPid > 0) runCatching { ProcessBuilder("su", "-c", "kill -TERM $rootPid").start().waitFor(2, TimeUnit.SECONDS) }
            if (!child.waitFor(2, TimeUnit.SECONDS)) {
                if (rootPid > 0) runCatching { ProcessBuilder("su", "-c", "kill -KILL $rootPid").start().waitFor(2, TimeUnit.SECONDS) }
                child.destroyForcibly()
            }
        }
        rootPid = 0
        pending.values.forEach { it.completeExceptionally(IllegalStateException("Root process stopped")) }; pending.clear()
    }
    /** root 进程的日志行：行首 ERROR 记为错误，其余记为信息 */
    private fun log(line: String) {
        if (line.startsWith("ERROR")) Log.e(LOG_TAG, line) else Log.i(LOG_TAG, line)
    }
    private const val LOG_TAG = "UnisonRoot"
    private fun quote(value: String) = "'" + value.replace("'", "'\\''") + "'"
}
