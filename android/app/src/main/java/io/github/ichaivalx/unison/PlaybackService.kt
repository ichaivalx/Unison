package io.github.ichaivalx.unison

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.net.wifi.WifiManager
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import io.github.ichaivalx.unison.capture.SourceController
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class PlaybackService : Service() {
    companion object {
        const val RECEIVE_START = "receive.start"
        const val RECEIVE_STOP = "receive.stop"
        const val SOURCE_START = "source.start"
        const val SOURCE_STOP = "source.stop"
        const val LATENCY = "source.latency"
        const val CALIBRATE = "source.calibrate"
        const val STOP_ALL = "stop.all"
        @Volatile var receiverRunning = false
        @Volatile var busy = false
        @Volatile var active = false
        @Volatile var offsetMs = 0f
        @Volatile var latencyMs = 50
        @Volatile var localDelayMs = 0
        @Volatile var message = ""
        @Volatile var wifiForce = "off"
        // 引擎和 WiFi 强制模式属于进程；服务快速重建时也要按顺序完成启停。
        private val worker = Executors.newSingleThreadExecutor()
        private val lines = ArrayDeque<String>()
        private fun log(line: String) = synchronized(lines) {
            android.util.Log.i("UnisonSource", line)
            if (line.startsWith("CALIBRATION ")) runCatching {
                val value = org.json.JSONObject(line.substringAfter(' '))
                if (value.optString("state") == "result") {
                    latencyMs = value.getInt("latencyUs") / 1000
                    localDelayMs = value.getInt("localDelayMs")
                }
            }
            lines.addLast(line)
            while (lines.size > 20) lines.removeFirst()
        }
        fun sourceLog(): String = synchronized(lines) { lines.joinToString("\n") }
    }

    private val main = Handler(Looper.getMainLooper())
    private lateinit var wifiLock: WifiManager.WifiLock
    private lateinit var multicastLock: WifiManager.MulticastLock
    private lateinit var wakeLock: PowerManager.WakeLock
    private lateinit var audioManager: AudioManager
    private var wifiForceAttempted = false
    @Volatile private var destroyed = false
    private val sourceStateWatch = object : Runnable {
        override fun run() {
            if (destroyed) return
            ReceiverEngine.setLocalSourceRunning(SourceController.isRunning)
            main.postDelayed(this, 250)
        }
    }
    private val devices = object : AudioDeviceCallback() {
        override fun onAudioDevicesAdded(addedDevices: Array<out AudioDeviceInfo>) {
            if (receiverRunning) ReceiverEngine.routeChanged()
        }
        override fun onAudioDevicesRemoved(removedDevices: Array<out AudioDeviceInfo>) {
            if (receiverRunning) ReceiverEngine.routeChanged()
        }
    }

    override fun onCreate() {
        super.onCreate()
        active = true
        val notifications = getSystemService(NotificationManager::class.java)
        notifications.createNotificationChannel(NotificationChannel("playback", "Unison 音频", NotificationManager.IMPORTANCE_LOW))
        startForeground(1, notification(), ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)
        val wifi = applicationContext.getSystemService(WifiManager::class.java)
        wifiLock = wifi.createWifiLock(WifiManager.WIFI_MODE_FULL_LOW_LATENCY, "Unison:audio")
        multicastLock = wifi.createMulticastLock("Unison:discovery")
        wakeLock = getSystemService(PowerManager::class.java).newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "Unison:audio")
        wifiLock.acquire()
        multicastLock.acquire()
        wakeLock.acquire()
        audioManager = getSystemService(AudioManager::class.java)
        audioManager.registerAudioDeviceCallback(devices, main)
        main.post(sourceStateWatch)
    }

    private fun notification(): Notification {
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val stop = PendingIntent.getService(this, 1, Intent(this, PlaybackService::class.java).setAction(STOP_ALL), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        return Notification.Builder(this, "playback")
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setContentTitle("Unison 正在运行")
            .setContentText("接收：${if (receiverRunning) "运行中" else "停止"}  音源：${if (SourceController.isRunning) "运行中" else "停止"}")
            .setContentIntent(open)
            .setOngoing(true)
            .addAction(Notification.Action.Builder(null, "全部停止", stop).build())
            .build()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val action = intent?.action
        busy = true
        worker.execute {
            if (!destroyed) {
                try {
                    when (action) {
                        RECEIVE_START -> {
                            if (SourceController.isRunning) {
                                message = "effect 音源已在本机直通播放；请先停止音源再启动接收"
                            } else {
                                ReceiverEngine.setLocalSourceRunning(false)
                                ReceiverEngine.setOffsetMs(offsetMs)
                                receiverRunning = ReceiverEngine.start()
                                message = if (receiverRunning) "" else "接收端启动失败（网络端口或输出设备不可用）"
                                if (receiverRunning) setWifiForce(true)
                            }
                        }
                        RECEIVE_STOP -> stopReceiver()
                        SOURCE_START -> {
                            if (receiverRunning) stopReceiver()
                            val started = SourceController.start(applicationContext, latencyMs, ::log)
                            message = if (started) "" else "音源启动失败，请检查 root 授权与下方输出"
                        }
                        SOURCE_STOP -> SourceController.stop()
                        LATENCY -> SourceController.setLatency(latencyMs)
                        CALIBRATE -> SourceController.calibrate()
                        STOP_ALL -> {
                            try { SourceController.stop() } finally { stopReceiver() }
                        }
                    }
                } catch (error: Exception) {
                    message = error.message ?: error.toString()
                    log(message)
                } finally {
                    ReceiverEngine.setLocalSourceRunning(SourceController.isRunning)
                }
            }
            main.post {
                busy = false
                if (!destroyed) {
                    getSystemService(NotificationManager::class.java).notify(1, notification())
                    if (!receiverRunning && !SourceController.isRunning) stopSelfResult(startId)
                }
            }
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        destroyed = true
        active = false
        main.removeCallbacks(sourceStateWatch)
        audioManager.unregisterAudioDeviceCallback(devices)
        worker.execute {
            try { SourceController.stop() } finally {
                stopReceiver()
                ReceiverEngine.setLocalSourceRunning(SourceController.isRunning)
                busy = false
            }
        }
        if (wifiLock.isHeld) wifiLock.release()
        if (multicastLock.isHeld) multicastLock.release()
        if (wakeLock.isHeld) wakeLock.release()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun stopReceiver() {
        try { ReceiverEngine.stop() } finally {
            receiverRunning = false
            setWifiForce(false)
        }
    }

    // 与接收启停共用后台队列；无 root 或命令失败不影响接收。
    private fun setWifiForce(enabled: Boolean) {
        if (enabled && wifiForce == "on") return
        if (!enabled && !wifiForceAttempted) return
        wifiForceAttempted = true
        var child: Process? = null
        try {
            val mode = if (enabled) "enabled" else "disabled"
            child = ProcessBuilder("su", "-c", "cmd wifi force-low-latency-mode $mode")
                .redirectErrorStream(true).start()
            child.outputStream.close()
            val completed = child.waitFor(30, TimeUnit.SECONDS)
            val output = if (completed) child.inputStream.bufferedReader().use { it.readText() } else ""
            // cmd wifi 底层失败时仍可能返回 0，启用与关闭都检查输出。
            val failed = listOf("fail", "error", "denied", "not permitted", "not found",
                "not supported", "unknown command", "失败", "错误", "拒绝")
                .any { output.contains(it, ignoreCase = true) }
            if (completed && child.exitValue() == 0 && !failed) {
                wifiForce = if (enabled) "on" else "off"
                wifiForceAttempted = enabled
            } else {
                wifiForce = "failed"
            }
        } catch (_: Exception) {
            wifiForce = "failed"
        } finally {
            child?.destroy()
        }
    }
}
