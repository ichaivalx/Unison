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
    companion object { var instance: AudioService? = null }
    private lateinit var wifi: WifiManager.WifiLock
    private lateinit var multicast: WifiManager.MulticastLock
    private lateinit var wake: PowerManager.WakeLock
    private lateinit var audio: AudioManager
    private val devices = object : AudioDeviceCallback() {
        override fun onAudioDevicesAdded(added: Array<out AudioDeviceInfo>) { if (NativeRuntime.receiverRequested) ReceiverEngine.routeChanged() }
        override fun onAudioDevicesRemoved(removed: Array<out AudioDeviceInfo>) { if (NativeRuntime.receiverRequested) ReceiverEngine.routeChanged() }
    }
    override fun onCreate() {
        super.onCreate(); instance = this; NativeRuntime.initialize(applicationContext)
        val notifications = getSystemService(NotificationManager::class.java)
        notifications.createNotificationChannel(NotificationChannel("unison_audio", "Unison", NotificationManager.IMPORTANCE_LOW))
        val launch = packageManager.getLaunchIntentForPackage(packageName)
        val open = launch?.let { PendingIntent.getActivity(this, 0, it, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE) }
        val stop = PendingIntent.getService(this, 1, Intent(this, AudioService::class.java).setAction("stop"), PendingIntent.FLAG_IMMUTABLE)
        val notification = Notification.Builder(this, "unison_audio").setSmallIcon(android.R.drawable.ic_media_play)
            .setContentTitle("Unison").setContentText("音频服务运行中").setContentIntent(open).setOngoing(true)
            .addAction(Notification.Action.Builder(null, "停止", stop).build()).build()
        startForeground(1, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)
        val manager = getSystemService(WifiManager::class.java)
        wifi = manager.createWifiLock(WifiManager.WIFI_MODE_FULL_LOW_LATENCY, "Unison:audio")
        multicast = manager.createMulticastLock("Unison:discovery")
        wake = getSystemService(PowerManager::class.java).newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "Unison:audio")
        wifi.acquire(); multicast.acquire(); wake.acquire()
        audio = getSystemService(AudioManager::class.java)
        audio.registerAudioDeviceCallback(devices, Handler(Looper.getMainLooper()))
    }
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == "stop") NativeRuntime.stopAll()
        refresh(); return START_NOT_STICKY
    }
    fun refresh() { if (!NativeRuntime.receiverRequested && !NativeRuntime.sourceRequested) stopSelf() }
    override fun onDestroy() {
        instance = null
        audio.unregisterAudioDeviceCallback(devices)
        if (wifi.isHeld) wifi.release(); if (multicast.isHeld) multicast.release(); if (wake.isHeld) wake.release()
        if (NativeRuntime.receiverRequested || NativeRuntime.sourceRequested) NativeRuntime.stopAll()
        super.onDestroy()
    }
    override fun onBind(intent: Intent?): IBinder? = null
}
