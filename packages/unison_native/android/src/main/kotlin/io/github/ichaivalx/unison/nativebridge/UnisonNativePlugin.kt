package io.github.ichaivalx.unison.nativebridge

import android.app.Activity
import android.Manifest
import android.content.pm.PackageManager
import android.media.AudioManager
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.EventChannel
import io.github.ichaivalx.unison.ReceiverEngine
import org.json.JSONObject
import java.util.concurrent.CompletableFuture

class UnisonNativePlugin : FlutterPlugin, MethodChannel.MethodCallHandler, EventChannel.StreamHandler, ActivityAware {
    private var activity: Activity? = null
    private var previousVolumeStream = 0
    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity; previousVolumeStream = binding.activity.volumeControlStream
        binding.activity.volumeControlStream = AudioManager.STREAM_MUSIC
    }
    override fun onDetachedFromActivity() { activity?.volumeControlStream = previousVolumeStream; activity = null }
    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)
    private lateinit var methods: MethodChannel
    private lateinit var events: EventChannel
    private val main = Handler(Looper.getMainLooper())
    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        NativeRuntime.initialize(binding.applicationContext)
        methods = MethodChannel(binding.binaryMessenger, "unison_native/methods")
        events = EventChannel(binding.binaryMessenger, "unison_native/events")
        methods.setMethodCallHandler(this); events.setStreamHandler(this)
    }
    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methods.setMethodCallHandler(null); events.setStreamHandler(null); NativeRuntime.detach()
    }
    override fun onListen(arguments: Any?, sink: EventChannel.EventSink) { NativeRuntime.listen(sink) }
    override fun onCancel(arguments: Any?) { NativeRuntime.detach() }
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            val args = (call.arguments as? Map<*, *>)?.let { JSONObject(it) } ?: JSONObject()
            val future: CompletableFuture<Any?> = when (call.method) {
                "receiverId" -> NativeRuntime.background { ReceiverEngine.receiverId() }
                "setKeepAlive" -> {
                    if (call.arguments == true) requestNotificationPermission()
                    NativeRuntime.setKeepAlive(call.arguments == true)
                }
                "startReceiver" -> NativeRuntime.startReceiver(args.getString("sourceHost"))
                "stopReceiver" -> NativeRuntime.stopReceiver()
                "setReceiverOffsetUs" -> NativeRuntime.background { ReceiverEngine.setOffsetUs((call.arguments as Number).toLong()); null }
                "volume" -> CompletableFuture.completedFuture(NativeRuntime.volume())
                "setVolume" -> NativeRuntime.background { NativeRuntime.setVolume((call.arguments as Number).toDouble()); null }
                "sourceAvailable" -> NativeRuntime.root("available").exceptionally { false }
                "startSource" -> { requestNotificationPermission(); NativeRuntime.startSource(args) }
                "stopSource" -> NativeRuntime.stopSource()
                "setSourceLatencyUs", "setLocalDelayUs", "mediaSeek", "mediaCommand" -> NativeRuntime.root(call.method, JSONObject().put("value", call.arguments))
                "setChannelDelays", "calibrate" -> NativeRuntime.root(call.method, args)
                "cancelCalibration" -> NativeRuntime.root("cancelCalibration")
                else -> { result.error("unsupported", "Unsupported Android capability: ${call.method}", null); return }
            }
            future.whenComplete { value, error -> main.post {
                if (error != null) result.error("native", error.cause?.message ?: error.message, null) else result.success(value)
            } }
        } catch (error: Throwable) { result.error("native", error.message, null) }
    }
    private fun requestNotificationPermission() {
        activity?.let {
            if (it.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED)
                it.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 47812)
        }
    }
}
