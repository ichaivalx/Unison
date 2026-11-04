package io.github.ichaivalx.unison.nativebridge;

import android.app.Activity;
import android.app.Instrumentation;
import android.content.Context;
import android.content.Intent;
import android.media.AudioManager;
import android.app.Notification;
import android.os.Bundle;
import org.json.JSONObject;
import java.lang.reflect.Method;
import java.lang.reflect.Proxy;
import java.util.Collections;
import java.util.HashSet;
import java.util.Set;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.TimeUnit;

// 目标为正式宿主，反射只用于绑定目标 ClassLoader，避免测试 APK 复制出第二套单例。
public final class NativeSmokeInstrumentation extends Instrumentation {
    private Bundle args;
    private Object runtime;
    private Class<?> runtimeClass;
    private Object engine;
    private Class<?> engineClass;
    private Object serviceCompanion;
    private Object service() throws Exception { return serviceCompanion.getClass().getMethod("getInstance").invoke(serviceCompanion); }
    private Object call(String method, Class<?>[] types, Object... values) throws Exception {
        return runtimeClass.getMethod(method, types).invoke(runtime, values);
    }
    private Object await(Object value) throws Exception { return ((CompletableFuture<?>) value).get(30, TimeUnit.SECONDS); }
    private JSONObject stats() throws Exception { return new JSONObject((String)engineClass.getMethod("statsJson").invoke(engine)); }
    @Override public void onCreate(Bundle arguments) { super.onCreate(arguments); args = arguments; start(); }
    @Override public void onStart() {
        Bundle result = new Bundle();
        Object originalSink = null;
        Double originalVolume = null;
        JSONObject originalSource = null;
        Boolean originalKeepAlive = null;
        Activity activity = null;
        Class<?> sinkClass = null;
        int code = Activity.RESULT_OK;
        try {
            Context context = getTargetContext();
            ClassLoader loader = context.getClassLoader();
            runtimeClass = Class.forName("io.github.ichaivalx.unison.nativebridge.NativeRuntime", true, loader);
            runtime = runtimeClass.getField("INSTANCE").get(null);
            engineClass = Class.forName("io.github.ichaivalx.unison.ReceiverEngine", true, loader);
            engine = engineClass.getField("INSTANCE").get(null);
            Class<?> serviceClass = Class.forName("io.github.ichaivalx.unison.nativebridge.AudioService", true, loader);
            serviceCompanion = serviceClass.getField("Companion").get(null);
            Intent launch = context.getPackageManager().getLaunchIntentForPackage(context.getPackageName());
            launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            activity = startActivitySync(launch);
            call("initialize", new Class<?>[]{Context.class}, context);
            sinkClass = Class.forName("io.flutter.plugin.common.EventChannel$EventSink", true, loader);
            originalSink = call("getSink", new Class<?>[]{});
            originalSource = new JSONObject(call("getSource", new Class<?>[]{}).toString());
            originalKeepAlive = (Boolean)call("getKeepAliveRequested", new Class<?>[]{});
            Set<String> events = Collections.synchronizedSet(new HashSet<>());
            Object listener = Proxy.newProxyInstance(loader, new Class<?>[]{sinkClass}, (proxy, method, values) -> {
                if (method.getName().equals("success") && values[0] instanceof java.util.Map) events.add(String.valueOf(((java.util.Map<?,?>)values[0]).get("type")));
                return null;
            });
            call("listen", new Class<?>[]{sinkClass}, listener);
            originalVolume = (Double)call("volume", new Class<?>[]{});
            Context nativeContext = (Context)call("getContext", new Class<?>[]{});
            AudioManager audio = nativeContext.getSystemService(AudioManager.class);
            int maximum = audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC);
            int level = Math.max(1, maximum / 2);
            call("setVolume", new Class<?>[]{double.class}, (level - 0.25) / maximum);
            Thread.sleep(100);
            int observed = audio.getStreamVolume(AudioManager.STREAM_MUSIC);
            if (observed != level) throw new IllegalStateException("Volume rounding mismatch: max=" + maximum + " expected=" + level + " observed=" + observed + " getter=" + call("volume", new Class<?>[]{}));
            result.putBoolean("volumeRounding", true);
            await(call("setKeepAlive", new Class<?>[]{boolean.class}, true));
            Object holder = service();
            if (holder == null) throw new IllegalStateException("Keep-alive returned before service ready");
            final Activity toFinish = activity;
            runOnMainSync(toFinish::finish);
            Thread.sleep(1000);
            // 已无 Activity、尚未接收时，远端启用也必须复用同一个前台服务。
            await(call("startReceiver", new Class<?>[]{String.class}, args.getString("sourceHost", "192.168.50.55")));
            long deadline = System.nanoTime() + 5_000_000_000L;
            JSONObject receiving;
            do { Thread.sleep(100); receiving = stats(); } while (!receiving.optBoolean("clockReady") && System.nanoTime() < deadline);
            if (!receiving.optBoolean("running") || !receiving.optBoolean("clockReady")) throw new IllegalStateException("Receiver did not synchronize: " + receiving);
            long before = receiving.getLong("outputFramesWritten");
            Thread.sleep(1500);
            JSONObject background = stats();
            if (!background.optBoolean("running") || background.getLong("outputFramesWritten") <= before) throw new IllegalStateException("Audio stopped after Activity finish");
            if (service() != holder) throw new IllegalStateException("Background receiver replaced keep-alive service");
            result.putString("receiverStats", background.toString());
            result.putLong("receiverId", (Long)engineClass.getMethod("receiverId").invoke(engine));
            await(call("stopReceiver", new Class<?>[]{}));
            Thread.sleep(300);
            if (service() != holder) throw new IllegalStateException("Stopping receiver stopped keep-alive service");
            activity = startActivitySync(launch);
            Object available = await(call("root", new Class<?>[]{String.class, JSONObject.class}, "available", new JSONObject()));
            if (!Boolean.TRUE.equals(available)) throw new IllegalStateException("Effect module unavailable");
            await(call("startSource", new Class<?>[]{JSONObject.class}, new JSONObject().put("latencyUs", 50000).put("localDelayUs", 1250)));
            Method notification = serviceClass.getDeclaredMethod("notification"); notification.setAccessible(true);
            Notification playingNotification = (Notification)notification.invoke(holder);
            if (playingNotification.actions.length != 2 || !"停止音源".contentEquals(playingNotification.actions[0].title) || !"退出".contentEquals(playingNotification.actions[1].title)) throw new IllegalStateException("Source notification actions mismatch");
            java.lang.reflect.Field rootField = Class.forName("io.github.ichaivalx.unison.capture.SourceController", true, loader).getDeclaredField("process");
            rootField.setAccessible(true); Process rootProcess = (Process)rootField.get(null);
            context.startService(new Intent(context, serviceClass).setAction("stop-source"));
            deadline = System.nanoTime() + 5_000_000_000L;
            while (((JSONObject)call("getSource", new Class<?>[]{})).optBoolean("running") && System.nanoTime() < deadline) Thread.sleep(50);
            if (((JSONObject)call("getSource", new Class<?>[]{})).optBoolean("running") || service() != holder || events.contains("exit")) throw new IllegalStateException("Stopping source exited keep-alive/control");
            if (rootField.get(null) != rootProcess || !rootProcess.isAlive()) throw new IllegalStateException("Stopping source replaced media root process");
            Notification idleNotification = (Notification)notification.invoke(holder);
            if (idleNotification.actions.length != 1 || !"退出".contentEquals(idleNotification.actions[0].title)) throw new IllegalStateException("Idle notification actions mismatch");
            final Activity sourceActivity = activity;
            runOnMainSync(sourceActivity::finish);
            Thread.sleep(1000);
            // 模拟远端在音源已停止、Activity 已销毁后再次开启；不允许新建服务。
            await(call("startSource", new Class<?>[]{JSONObject.class}, new JSONObject().put("latencyUs", 50000).put("localDelayUs", 1250)));
            if (service() != holder || rootField.get(null) != rootProcess) throw new IllegalStateException("Background source replaced service/root process");
            // AUDIO 由 tap 帧生成；验证采集链路，不依赖房间噪声下的麦克风检出结果。
            java.net.DatagramSocket tap = new java.net.DatagramSocket(); tap.setSoTimeout(100);
            java.net.InetAddress loopback = java.net.InetAddress.getByName("127.0.0.1");
            byte[] subscribe = java.nio.ByteBuffer.allocate(18).order(java.nio.ByteOrder.LITTLE_ENDIAN)
                .putInt(0x4e534e55).put((byte)1).put((byte)2).putShort((short)0)
                .putLong((Long)engineClass.getMethod("receiverId").invoke(engine)).putShort((short)0).array();
            java.util.concurrent.atomic.AtomicBoolean observing = new java.util.concurrent.atomic.AtomicBoolean(true);
            java.util.concurrent.atomic.AtomicInteger packets = new java.util.concurrent.atomic.AtomicInteger();
            Thread observer = new Thread(() -> {
                long last = 0;
                while (observing.get()) {
                    try {
                        if (System.nanoTime() - last >= 1_000_000_000L) { tap.send(new java.net.DatagramPacket(subscribe, subscribe.length, loopback, 47800)); last = System.nanoTime(); }
                        java.net.DatagramPacket packet = new java.net.DatagramPacket(new byte[2048], 2048); tap.receive(packet);
                        if (packet.getLength() == 988 && packet.getData()[5] == 5) packets.incrementAndGet();
                    } catch (java.net.SocketTimeoutException ignored) {} catch (java.io.IOException error) { return; }
                }
            }, "background-source-probe");
            observer.start();
            try {
                await(call("root", new Class<?>[]{String.class, JSONObject.class}, "calibrate", new JSONObject().put("receiverIds", new org.json.JSONArray()).put("bands", new org.json.JSONArray().put("midHigh"))));
            } finally {
                observing.set(false);
                byte[] bye = java.nio.ByteBuffer.allocate(8).order(java.nio.ByteOrder.LITTLE_ENDIAN)
                    .putInt(0x4e534e55).put((byte)1).put((byte)6).putShort((short)0).array();
                try { tap.send(new java.net.DatagramPacket(bye, bye.length, loopback, 47800)); } finally { tap.close(); observer.join(1000); }
            }
            if (packets.get() == 0) throw new IllegalStateException("Background source did not capture audio packets");
            result.putInt("backgroundAudioPackets", packets.get()); result.putBoolean("backgroundSourceReused", true);
            await(call("stopSource", new Class<?>[]{}));
            context.startService(new Intent(context, serviceClass).setAction("exit"));
            deadline = System.nanoTime() + 5_000_000_000L;
            while ((!events.contains("exit") || service() != null) && System.nanoTime() < deadline) Thread.sleep(50);
            if (service() != null || (Boolean)call("getKeepAliveRequested", new Class<?>[]{}) || stats().optBoolean("running")) throw new IllegalStateException("Notification exit did not release service/audio");
            if (!events.containsAll(java.util.Arrays.asList("source", "volume", "media", "receiver", "calibration", "exit"))) throw new IllegalStateException("Missing initial/progress events: " + events);
            result.putString("events", events.toString()); result.putBoolean("ok", true);
        } catch (Throwable error) {
            code = Activity.RESULT_CANCELED; result.putBoolean("ok", false); result.putString("error", android.util.Log.getStackTraceString(error));
        } finally {
            if (runtime != null) {
                try { await(call("stopReceiver", new Class<?>[]{})); } catch (Exception ignored) {}
                try { await(call("stopSource", new Class<?>[]{})); } catch (Exception ignored) {}
                if (originalSource != null) {
                    try { await(call("root", new Class<?>[]{String.class, JSONObject.class}, "setLocalDelayUs", new JSONObject().put("value", originalSource.optLong("localDelayUs")))); } catch (Exception ignored) {}
                    try { await(call("root", new Class<?>[]{String.class, JSONObject.class}, "setSourceLatencyUs", new JSONObject().put("value", originalSource.optLong("latencyUs", 50000)))); } catch (Exception ignored) {}
                }
                if (originalVolume != null) try { call("setVolume", new Class<?>[]{double.class}, originalVolume); } catch (Exception ignored) {}
                if (originalKeepAlive != null) try { await(call("setKeepAlive", new Class<?>[]{boolean.class}, originalKeepAlive)); } catch (Exception ignored) {}
                if (originalSink != null && sinkClass != null) try { call("listen", new Class<?>[]{sinkClass}, originalSink); } catch (Exception ignored) {}
            }
        }
        finish(code, result);
    }
}
