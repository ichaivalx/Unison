package io.github.ichaivalx.unison

import android.app.Application
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

/** 持有运行控制面的 Flutter 引擎：界面被系统回收后引擎照常运行，再次打开时复用 */
class UnisonApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        // 插件声明的其他进程不运行控制面
        if (getProcessName() != packageName) return
        val engine = FlutterEngine(this)
        MethodChannel(engine.dartExecutor.binaryMessenger, "unison/app").setMethodCallHandler { call, result ->
            when (call.method) {
                "deviceName" -> result.success(
                    Settings.Global.getString(contentResolver, Settings.Global.DEVICE_NAME) ?: Build.MODEL
                )
                else -> result.notImplemented()
            }
        }
        engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        FlutterEngineCache.getInstance().put(ENGINE_ID, engine)
    }

    companion object {
        const val ENGINE_ID = "unison"
    }
}
