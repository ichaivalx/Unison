package io.github.ichaivalx.unison

import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    override fun getCachedEngineId(): String = UnisonApplication.ENGINE_ID

    override fun shouldDestroyEngineWithHost(): Boolean = false
}
