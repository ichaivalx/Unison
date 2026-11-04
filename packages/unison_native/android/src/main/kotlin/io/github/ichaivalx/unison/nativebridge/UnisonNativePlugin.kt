package io.github.ichaivalx.unison.nativebridge

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.EventChannel

class UnisonNativePlugin : FlutterPlugin, MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    private lateinit var methods: MethodChannel
    private lateinit var events: EventChannel
    private lateinit var context: Context
    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        methods = MethodChannel(binding.binaryMessenger, "unison_native/methods")
        events = EventChannel(binding.binaryMessenger, "unison_native/events")
        methods.setMethodCallHandler(this); events.setStreamHandler(this)
    }
    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methods.setMethodCallHandler(null); events.setStreamHandler(null)
    }
    override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {}
    override fun onCancel(arguments: Any?) {}
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method == "sourceAvailable") result.success(false)
        else result.error("unsupported", "Native capability is being initialized", null)
    }
}
