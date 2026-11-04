package io.github.ichaivalx.unison

import android.app.Activity
import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Typeface
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.WindowInsets
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import io.github.ichaivalx.unison.capture.SourceController
import org.json.JSONObject
import java.util.Locale

class MainActivity : Activity() {
    private val handler = Handler(Looper.getMainLooper())
    private lateinit var stats: TextView
    private lateinit var offset: TextView
    private lateinit var latency: TextView
    private lateinit var localDelay: TextView
    private lateinit var logs: TextView
    private lateinit var state: TextView
    private lateinit var sourceState: TextView
    private lateinit var message: TextView
    private var lastFramesWritten = -1L
    private val refresh = object : Runnable {
        override fun run() {
            state.text = "接收端：${if (PlaybackService.receiverRunning) "运行中" else "停止"}"
            sourceState.text = "音源（effect）：${if (SourceController.isRunning) "运行中" else "停止"}"
            offset.text = "本机偏移：${PlaybackService.offsetMs.toInt()} ms（正值更晚发声）"
            latency.text = "目标延迟：${PlaybackService.latencyMs} ms"
            localDelay.text = "本机延迟：${PlaybackService.localDelayMs} ms（音效直通，无需本机接收）"
            logs.text = PlaybackService.sourceLog().ifEmpty { "音源进程输出（最近 20 行）" }
            message.text = if (PlaybackService.busy) "正在处理…" else PlaybackService.message
            val value = JSONObject(ReceiverEngine.statsJson())
            fun number(name: String) = String.format(Locale.US, "%.3f", value.optDouble(name, 0.0))
            val outputOpen = value.optBoolean("outputOpen")
            val written = value.optLong("outputFramesWritten")
            val growth = when {
                !outputOpen -> "已关闭"
                lastFramesWritten < 0 -> "等待采样"
                written < lastFramesWritten -> "重新计数"
                written > lastFramesWritten -> "增长"
                else -> "未增长"
            }
            lastFramesWritten = if (outputOpen) written else -1
            stats.text = "音源 ${value.optString("source").ifEmpty { "等待发现" }}  时钟${if (value.optBoolean("clockReady")) "已同步" else "等待同步"}\n" +
                "时钟 offset ${number("clockOffsetMs")} ms  最短 RTT ${number("minRttMs")} ms\n" +
                "缓冲 ${number("bufferMs")} ms  同步误差 ${number("syncErrorMs")} ms\n" +
                "丢包 ${value.optLong("lostPackets")}  晚到 ${value.optLong("latePackets")}  重定位 ${value.optLong("relocations")}\n" +
                "晚到 ${value.optLong("latePacketsPerSecond")} 包/秒  avg/max ${number("lateAvgMs")}/${number("lateMaxMs")} ms（收包−应播）\n" +
                "速度修正 ${number("speedPpm")} ppm\n" +
                "时间戳 ${if (value.optString("timestamp") == "real") "真实" else "回退"}  输出 ${value.optInt("outputRate")} Hz ${if (value.optBoolean("outputOpen")) "已打开" else "关闭"}\n" +
                "设备 id ${value.optInt("outputDeviceId")}  usage ${value.optString("outputUsage")}\n" +
                "sharing ${value.optString("outputSharingMode")}  performance ${value.optString("outputPerformanceMode")}\n" +
                "已写帧 $written（$growth）\n" +
                "本地 xrun ${value.optLong("xruns")}  wifiForce=${PlaybackService.wifiForce}"
            handler.postDelayed(this, 250)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val root = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        val scroll = ScrollView(this).apply { addView(root) }
        scroll.setOnApplyWindowInsetsListener { view, insets ->
            val bars = insets.getInsets(WindowInsets.Type.systemBars() or WindowInsets.Type.displayCutout())
            view.setPadding(bars.left, bars.top, bars.right, bars.bottom)
            insets
        }
        root.setPadding(dp(16), dp(12), dp(16), dp(24))
        fun label(text: String, size: Float = 16f): TextView = TextView(this).apply {
            this.text = text
            textSize = size
            setPadding(0, dp(8), 0, dp(8))
            root.addView(this)
        }
        fun row(vararg items: Pair<String, () -> Unit>) {
            val layout = LinearLayout(this)
            for ((text, action) in items) layout.addView(Button(this).apply {
                this.text = text
                setOnClickListener { action() }
            }, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
            root.addView(layout)
        }
        label("Unison", 28f)
        message = label("")
        state = label("接收端", 21f)
        row("开始接收" to { command(PlaybackService.RECEIVE_START) }, "停止接收" to { command(PlaybackService.RECEIVE_STOP) })
        offset = label("")
        fun shift(ms: Int) {
            PlaybackService.offsetMs += ms
            ReceiverEngine.setOffsetMs(PlaybackService.offsetMs)
        }
        row("−10 ms" to { shift(-10) }, "−1 ms" to { shift(-1) }, "+1 ms" to { shift(1) }, "+10 ms" to { shift(10) })
        stats = label("", 13f).apply { typeface = Typeface.MONOSPACE; setTextIsSelectable(true) }
        sourceState = label("音源", 21f)
        row("启动音源" to { command(PlaybackService.SOURCE_START) }, "停止音源" to { command(PlaybackService.SOURCE_STOP) })
        latency = label("")
        fun adjustLatency(ms: Int) {
            PlaybackService.latencyMs += ms
            if (SourceController.isRunning) command(PlaybackService.LATENCY)
        }
        row("−50 ms" to { adjustLatency(-50) }, "−5 ms" to { adjustLatency(-5) },
            "+5 ms" to { adjustLatency(5) }, "+50 ms" to { adjustLatency(50) })
        localDelay = label("")
        fun adjustLocalDelay(ms: Int) {
            PlaybackService.localDelayMs = (PlaybackService.localDelayMs + ms).coerceAtLeast(0)
            if (SourceController.isRunning) command(PlaybackService.LOCAL_DELAY)
        }
        row("−5 ms" to { adjustLocalDelay(-5) }, "+5 ms" to { adjustLocalDelay(5) })
        logs = label("", 12f).apply { typeface = Typeface.MONOSPACE; setTextIsSelectable(true) }
        setContentView(scroll)
        if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED)
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1)
    }

    private fun dp(value: Int) = (value * resources.displayMetrics.density).toInt()
    private fun command(action: String) {
        if (!PlaybackService.active && (action == PlaybackService.RECEIVE_STOP || action == PlaybackService.SOURCE_STOP)) return
        startForegroundService(Intent(this, PlaybackService::class.java).setAction(action))
    }
    override fun onResume() {
        super.onResume()
        handler.post(refresh)
    }
    override fun onPause() {
        handler.removeCallbacks(refresh)
        super.onPause()
    }
}
