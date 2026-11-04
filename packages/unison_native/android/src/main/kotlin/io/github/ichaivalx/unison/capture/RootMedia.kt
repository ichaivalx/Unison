package io.github.ichaivalx.unison.capture

import android.content.Context
import android.media.MediaMetadata
import android.media.session.MediaController
import android.media.session.MediaSessionManager
import android.media.session.PlaybackState
import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import org.json.JSONObject

internal class RootMedia(context: Context) {
    private val manager = context.getSystemService(MediaSessionManager::class.java)
    private val packages = context.packageManager
    private val thread = HandlerThread("root-media").apply { start() }
    private val handler = Handler(thread.looper)
    @Volatile private var controller: MediaController? = null
    @Volatile private var closed = false
    private var previous = ""
    private val update = object : Runnable {
        override fun run() {
            if (closed) return
            runCatching {
                val value = snapshot()
                val text = value?.toString() ?: "null"
                if (text != previous) { previous = text; RootEvents.emit("media", value) }
            }
            handler.postDelayed(this, 250)
        }
    }
    init { handler.post(update) }
    fun snapshot(): JSONObject? {
        val sessions = manager.getActiveSessions(null)
        val active = sessions.firstOrNull { it.playbackState?.state == PlaybackState.STATE_PLAYING }
            ?: sessions.firstOrNull { it.playbackState?.state == PlaybackState.STATE_PAUSED }
            ?: sessions.firstOrNull { it.playbackState?.state != PlaybackState.STATE_NONE && it.metadata != null }
        controller = active
        val state = active?.playbackState
        val metadata = active?.metadata
        val value = if (active == null || state == null) null else JSONObject()
            .put("packageName", active.packageName)
            .put("appName", runCatching {
                packages.getApplicationInfo(active.packageName, 0).loadLabel(packages).toString().ifBlank { active.packageName }
            }.getOrDefault(active.packageName))
            .put("title", metadata?.getString(MediaMetadata.METADATA_KEY_TITLE) ?: JSONObject.NULL)
            .put("artist", metadata?.getString(MediaMetadata.METADATA_KEY_ARTIST) ?: JSONObject.NULL)
            .put("durationUs", metadata?.takeIf { it.containsKey(MediaMetadata.METADATA_KEY_DURATION) }
                ?.getLong(MediaMetadata.METADATA_KEY_DURATION)?.times(1000) ?: JSONObject.NULL)
            .put("positionUs", state.position.coerceAtLeast(0) * 1000)
            .put("positionUpdatedAtUs", System.nanoTime() / 1000 - (SystemClock.elapsedRealtime() - state.lastPositionUpdateTime) * 1000)
            .put("speed", state.playbackSpeed.toDouble())
            .put("playing", state.state == PlaybackState.STATE_PLAYING)
            .put("canSeek", state.actions and PlaybackState.ACTION_SEEK_TO != 0L)
        return value
    }
    fun command(command: String) {
        snapshot()
        val controls = checkNotNull(controller) { "No media session" }.transportControls
        when (command) { "play" -> controls.play(); "pause" -> controls.pause(); "next" -> controls.skipToNext(); "previous" -> controls.skipToPrevious(); else -> error("Unknown media command") }
    }
    fun seek(us: Long) { snapshot(); require(us >= 0); checkNotNull(controller) { "No media session" }.transportControls.seekTo(us / 1000) }
    fun close() { closed = true; handler.removeCallbacksAndMessages(null); thread.quitSafely() }
}
