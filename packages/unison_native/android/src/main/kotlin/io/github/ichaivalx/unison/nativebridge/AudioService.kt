package io.github.ichaivalx.unison.nativebridge

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
import io.github.ichaivalx.unison.ReceiverEngine

class AudioService : Service() {
    companion object { @Volatile var instance: AudioService? = null }
    private lateinit var wifi: WifiManager.WifiLock
    private lateinit var multicast: WifiManager.MulticastLock
    private lateinit var wake: PowerManager.WakeLock
    private lateinit var audio: AudioManager
    private var notifiedText = ""
    private val devices = object : AudioDeviceCallback() {
        override fun onAudioDevicesAdded(added: Array<out AudioDeviceInfo>) { if (NativeRuntime.receiverRequested) ReceiverEngine.routeChanged() }
        override fun onAudioDevicesRemoved(removed: Array<out AudioDeviceInfo>) { if (NativeRuntime.receiverRequested) ReceiverEngine.routeChanged() }
    }
    override fun onCreate() {
        super.onCreate(); NativeRuntime.initialize(applicationContext)
        val notifications = getSystemService(NotificationManager::class.java)
        notifications.createNotificationChannel(NotificationChannel("unison_audio", "Unison", NotificationManager.IMPORTANCE_LOW))
        startForeground(1, notification(), ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)
        val manager = getSystemService(WifiManager::class.java)
        wifi = manager.createWifiLock(WifiManager.WIFI_MODE_FULL_LOW_LATENCY, "Unison:audio")
        multicast = manager.createMulticastLock("Unison:discovery")
        wake = getSystemService(PowerManager::class.java).newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "Unison:audio")
        wifi.acquire(); multicast.acquire(); wake.acquire()
        audio = getSystemService(AudioManager::class.java)
        audio.registerAudioDeviceCallback(devices, Handler(Looper.getMainLooper()))
        instance = this
    }
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        NativeRuntime.serviceStarted()
        if (intent?.action == "exit") NativeRuntime.notificationExit()
        else if (intent?.action == "stop-source") NativeRuntime.stopSource().whenComplete { _, _ -> NativeRuntime.emit("exit", null) }
        refresh(); return START_NOT_STICKY
    }
    private fun text() = when {
        NativeRuntime.sourceRequested -> "音源运行中"
        NativeRuntime.receiverRequested -> "正在接收音频"
        else -> "已连接 Unison"
    }
    private fun notification(): Notification {
        notifiedText = text()
        val launch = packageManager.getLaunchIntentForPackage(packageName)
        val open = launch?.let { PendingIntent.getActivity(this, 0, it, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE) }
        val sourceOnly = NativeRuntime.sourceRequested && !NativeRuntime.keepAliveRequested
        val exit = PendingIntent.getService(this, 2, Intent(this, AudioService::class.java)
            .setAction(if (sourceOnly) "stop-source" else "exit"), PendingIntent.FLAG_IMMUTABLE)
        return Notification.Builder(this, "unison_audio").setSmallIcon(android.R.drawable.ic_media_play)
            .setContentTitle("Unison").setContentText(notifiedText).setContentIntent(open).setOngoing(true)
            .addAction(Notification.Action.Builder(null, if (sourceOnly) "停止音源" else "退出", exit).build()).build()
    }
    fun refresh() {
        if (!NativeRuntime.holdsService()) stopSelf()
        else if (notifiedText != text()) getSystemService(NotificationManager::class.java).notify(1, notification())
    }
    override fun onDestroy() {
        instance = null
        audio.unregisterAudioDeviceCallback(devices)
        if (wifi.isHeld) wifi.release(); if (multicast.isHeld) multicast.release(); if (wake.isHeld) wake.release()
        // 角色切换时旧服务的 stopSelf 可能已排入主线程；只重建持有者，不重建音效或接收流。
        if (NativeRuntime.holdsService()) runCatching {
            startForegroundService(Intent(this, AudioService::class.java).setAction("keep"))
        }.onFailure { NativeRuntime.notificationExit() }
        super.onDestroy()
    }
    override fun onBind(intent: Intent?): IBinder? = null
}
