package io.github.ichaivalx.unison.capture

import android.content.Context

object SourceController {
    /** 用 su 启动音源进程；onLine 在后台线程接收输出。 */
    fun start(context: Context, latencyMs: Int, onLine: (String) -> Unit): Boolean = false
    fun stop() {}
    fun setLatency(latencyMs: Int) {}
    val isRunning: Boolean get() = false
}
