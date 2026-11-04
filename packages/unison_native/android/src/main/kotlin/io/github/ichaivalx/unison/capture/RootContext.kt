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
import android.app.Application
import android.app.Instrumentation
import android.content.AttributionSource
import android.content.Context
import android.content.ContextWrapper
import android.content.pm.ApplicationInfo
import android.os.Looper

internal object RootContext {
    private var instance: Context? = null
    @Synchronized
    fun create(): Context {
        instance?.let { return it }
        // app_process 不经过 Zygote 的媒体 mainline 初始化。
        val mediaInitializer = Class.forName("android.media.MediaFrameworkPlatformInitializer")
        if (mediaInitializer.getDeclaredMethod("getMediaServiceManager").invoke(null) == null) {
            val serviceManager = Class.forName("android.media.MediaServiceManager")
            mediaInitializer.getDeclaredMethod("setMediaServiceManager", serviceManager)
                .invoke(null, serviceManager.getDeclaredConstructor().newInstance())
        }
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
        instance = context
        return context
    }
}
