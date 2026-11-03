/*
 * Context 初始化与 AudioPolicy 反射调用改写自 Genymobile/scrcpy：
 * server/src/main/java/com/genymobile/scrcpy/{FakeContext,Workarounds}.java
 * server/src/main/java/com/genymobile/scrcpy/audio/AudioPlaybackCapture.java
 * https://github.com/Genymobile/scrcpy
 * Copyright (C) 2018 Genymobile
 * Copyright (C) 2018-2026 Romain Vimont
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
package io.github.ichaivalx.unison.capture

import android.annotation.SuppressLint
import android.app.Application
import android.app.Instrumentation
import android.content.AttributionSource
import android.content.Context
import android.content.ContextWrapper
import android.content.pm.ApplicationInfo
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.os.Looper

@SuppressLint("PrivateApi", "DiscouragedPrivateApi", "SoonBlockedPrivateApi", "MissingPermission")
internal class PlaybackCapture {
    private val policyClass = Class.forName("android.media.audiopolicy.AudioPolicy")
    private val context = systemContext()
    private val manager = AudioManager::class.java.getDeclaredConstructor(Context::class.java)
        .newInstance(context)
    // 先解析注销方法，不能在没有清理能力的情况下注册策略。
    private val unregister = AudioManager::class.java.getMethod("unregisterAudioPolicy", policyClass)
    private var policy: Any? = null
    private var registered = false
    var recorder: AudioRecord? = null
        private set

    fun start(excludeUid: Int, duplicate: Boolean) {
        val ruleClass = Class.forName("android.media.audiopolicy.AudioMixingRule")
        val ruleBuilderClass = Class.forName("android.media.audiopolicy.AudioMixingRule\$Builder")
        val ruleBuilder = ruleBuilderClass.getConstructor().newInstance()
        ruleBuilderClass.getMethod("setTargetMixRole", Int::class.javaPrimitiveType)
            .invoke(ruleBuilder, ruleClass.getField("MIX_ROLE_PLAYERS").getInt(null))
        val addRule = ruleBuilderClass.getMethod("addMixRule", Int::class.javaPrimitiveType, Any::class.java)
        val usageRule = ruleClass.getField("RULE_MATCH_ATTRIBUTE_USAGE").getInt(null)
        for (usage in intArrayOf(AudioAttributes.USAGE_MEDIA, AudioAttributes.USAGE_GAME, AudioAttributes.USAGE_UNKNOWN)) {
            addRule.invoke(ruleBuilder, usageRule, AudioAttributes.Builder().setUsage(usage).build())
        }
        ruleBuilderClass.getMethod("excludeMixRule", Int::class.javaPrimitiveType, Any::class.java)
            .invoke(ruleBuilder, ruleClass.getField("RULE_MATCH_UID").getInt(null), excludeUid)

        val format = AudioFormat.Builder().setSampleRate(48_000)
            .setChannelMask(AudioFormat.CHANNEL_OUT_STEREO)
            .setEncoding(AudioFormat.ENCODING_PCM_16BIT).build()
        val mixClass = Class.forName("android.media.audiopolicy.AudioMix")
        val privilegedMethod = ruleBuilderClass.methods.firstOrNull {
            it.name in arrayOf("allowPrivilegedPlaybackCapture", "setAllowPrivilegedPlaybackCapture") &&
                it.parameterTypes.contentEquals(arrayOf(Boolean::class.javaPrimitiveType))
        }
        if (privilegedMethod != null) {
            // AOSP 14/15 只允许 <=16kHz 单声道；LOOP_BACK 本身不受该开关影响。
            val formatError = mixClass.getMethod("canBeUsedForPrivilegedMediaCapture", AudioFormat::class.java)
                .invoke(null, format) as String?
            if (formatError == null) {
                privilegedMethod.invoke(ruleBuilder, true)
                println("INFO privileged_capture=enabled")
            } else {
                println("INFO privileged_capture=unavailable reason=$formatError mode=${if (duplicate) "dup" else "intercept"}")
            }
        } else {
            println("INFO privileged_capture=unavailable reason=no_hidden_api")
        }
        val rule = ruleBuilderClass.getMethod("build").invoke(ruleBuilder)
        val mixBuilderClass = Class.forName("android.media.audiopolicy.AudioMix\$Builder")
        val mixBuilder = mixBuilderClass.getConstructor(ruleClass).newInstance(rule)
        mixBuilderClass.getMethod("setFormat", AudioFormat::class.java).invoke(mixBuilder, format)
        val loopback = mixClass.getField("ROUTE_FLAG_LOOP_BACK").getInt(null)
        val render = if (duplicate) mixClass.getField("ROUTE_FLAG_RENDER").getInt(null) else 0
        mixBuilderClass.getMethod("setRouteFlags", Int::class.javaPrimitiveType).invoke(mixBuilder, loopback or render)
        val mix = mixBuilderClass.getMethod("build").invoke(mixBuilder)

        val builderClass = Class.forName("android.media.audiopolicy.AudioPolicy\$Builder")
        val builder = builderClass.getConstructor(Context::class.java).newInstance(context)
        builderClass.getMethod("addMix", mixClass).invoke(builder, mix)
        val builtPolicy = builderClass.getMethod("build").invoke(builder)
        policy = builtPolicy
        // 14/15 的 IAudioService 参数不同，交给本机 AudioManager 封装，避免直接反射 AIDL。
        val register = AudioManager::class.java.getDeclaredMethod("registerAudioPolicyStatic", policyClass)
        register.isAccessible = true
        val result = register.invoke(null, builtPolicy) as Int
        check(result == 0) { "registerAudioPolicy returned $result" }
        registered = true
        val record = policyClass.getMethod("createAudioRecordSink", mixClass).invoke(builtPolicy, mix) as AudioRecord?
        recorder = record
        check(record != null && record.state == AudioRecord.STATE_INITIALIZED) { "AudioRecord sink is not initialized" }
        record.startRecording()
        check(record.recordingState == AudioRecord.RECORDSTATE_RECORDING) { "AudioRecord did not start recording" }
    }

    fun close(): Boolean {
        var unregistered = !registered
        try {
            if (registered) {
                try {
                    unregister.invoke(manager, policy)
                    unregistered = true
                } catch (error: Exception) {
                    println("ERROR unregister_sync=${error.cause ?: error}")
                    // 同步注销失败仍尝试系统提供的异步入口。
                    val async = AudioManager::class.java.getDeclaredMethod("unregisterAudioPolicyAsyncStatic", policyClass)
                    async.isAccessible = true
                    async.invoke(null, policy)
                    unregistered = true
                }
            }
        } catch (error: Exception) {
            println("ERROR unregister_async=${error.cause ?: error}")
        } finally {
            registered = !unregistered
            runCatching { recorder?.release() }
                .onFailure { println("ERROR release_audio_record=$it") }
            recorder = null
        }
        return unregistered
    }

    private fun systemContext(): Context {
        if (Looper.myLooper() == null) Looper.prepareMainLooper()
        val activityThreadClass = Class.forName("android.app.ActivityThread")
        val constructor = activityThreadClass.getDeclaredConstructor().apply { isAccessible = true }
        val activityThread = constructor.newInstance()
        activityThreadClass.getDeclaredField("sCurrentActivityThread").apply { isAccessible = true }
            .set(null, activityThread)
        activityThreadClass.getDeclaredField("mSystemThread").apply { isAccessible = true }
            .setBoolean(activityThread, true)
        // Samsung 的系统 Context 会访问 ConfigurationController，必须先初始化。
        val configurationClass = Class.forName("android.app.ConfigurationController")
        val configuration = configurationClass.getDeclaredConstructor(Class.forName("android.app.ActivityThreadInternal"))
            .apply { isAccessible = true }.newInstance(activityThread)
        activityThreadClass.getDeclaredField("mConfigurationController").apply { isAccessible = true }
            .set(activityThread, configuration)
        val bindClass = Class.forName("android.app.ActivityThread\$AppBindData")
        val bind = bindClass.getDeclaredConstructor().apply { isAccessible = true }.newInstance()
        val info = ApplicationInfo().apply { packageName = "com.android.shell" }
        bindClass.getDeclaredField("appInfo").apply { isAccessible = true }.set(bind, info)
        activityThreadClass.getDeclaredField("mBoundApplication").apply { isAccessible = true }.set(activityThread, bind)
        val base = activityThreadClass.getDeclaredMethod("getSystemContext").apply { isAccessible = true }
            .invoke(activityThread) as Context
        val context = object : ContextWrapper(base) {
            override fun getPackageName() = "com.android.shell"
            override fun getOpPackageName() = packageName
            override fun getAttributionSource(): AttributionSource = AttributionSource.Builder(2000)
                .setPackageName(packageName).build()
            override fun getDeviceId() = 0
            override fun getApplicationContext(): Context = this
        }
        val application = Instrumentation.newApplication(Application::class.java, context)
        activityThreadClass.getDeclaredField("mInitialApplication").apply { isAccessible = true }
            .set(activityThread, application)
        return context
    }
}
