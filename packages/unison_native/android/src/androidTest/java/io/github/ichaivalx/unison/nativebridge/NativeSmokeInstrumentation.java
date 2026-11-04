package io.github.ichaivalx.unison.nativebridge;

import android.app.Activity;
import android.app.Instrumentation;
import android.content.Context;
import android.content.Intent;
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
            Intent launch = context.getPackageManager().getLaunchIntentForPackage(context.getPackageName());
            launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            activity = startActivitySync(launch);
            call("initialize", new Class<?>[]{Context.class}, context);
            sinkClass = Class.forName("io.flutter.plugin.common.EventChannel$EventSink", true, loader);
            originalSink = call("getSink", new Class<?>[]{});
            originalSource = new JSONObject(call("getSource", new Class<?>[]{}).toString());
            Set<String> events = Collections.synchronizedSet(new HashSet<>());
            Object listener = Proxy.newProxyInstance(loader, new Class<?>[]{sinkClass}, (proxy, method, values) -> {
                if (method.getName().equals("success") && values[0] instanceof java.util.Map) events.add(String.valueOf(((java.util.Map<?,?>)values[0]).get("type")));
                return null;
            });
            call("listen", new Class<?>[]{sinkClass}, listener);
            originalVolume = (Double)call("volume", new Class<?>[]{});
            call("setVolume", new Class<?>[]{double.class}, 0.5);
            double actual = (Double)call("volume", new Class<?>[]{});
            if (Math.abs(actual - 0.5) > 0.1) throw new IllegalStateException("Volume write mismatch");
            await(call("startReceiver", new Class<?>[]{String.class}, args.getString("sourceHost", "192.168.50.55")));
            long deadline = System.nanoTime() + 5_000_000_000L;
            JSONObject receiving;
            do { Thread.sleep(100); receiving = stats(); } while (!receiving.optBoolean("clockReady") && System.nanoTime() < deadline);
            if (!receiving.optBoolean("running") || !receiving.optBoolean("clockReady")) throw new IllegalStateException("Receiver did not synchronize: " + receiving);
            long before = receiving.getLong("outputFramesWritten");
            final Activity toFinish = activity;
            runOnMainSync(toFinish::finish);
            Thread.sleep(1500);
            JSONObject background = stats();
            if (!background.optBoolean("running") || background.getLong("outputFramesWritten") <= before) throw new IllegalStateException("Audio stopped after Activity finish");
            result.putString("receiverStats", background.toString());
            result.putLong("receiverId", (Long)engineClass.getMethod("receiverId").invoke(engine));
            await(call("stopReceiver", new Class<?>[]{}));
            Object available = await(call("root", new Class<?>[]{String.class, JSONObject.class}, "available", new JSONObject()));
            if (!Boolean.TRUE.equals(available)) throw new IllegalStateException("Effect module unavailable");
            await(call("startSource", new Class<?>[]{JSONObject.class}, new JSONObject().put("latencyUs", 50000).put("localDelayUs", 1250)));
            await(call("root", new Class<?>[]{String.class, JSONObject.class}, "calibrate", new JSONObject().put("receiverIds", new org.json.JSONArray()).put("bands", new org.json.JSONArray().put("midHigh"))));
            await(call("stopSource", new Class<?>[]{}));
            if (!events.containsAll(java.util.Arrays.asList("source", "volume", "media", "receiver", "calibration"))) throw new IllegalStateException("Missing initial/progress events: " + events);
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
                if (originalSink != null && sinkClass != null) try { call("listen", new Class<?>[]{sinkClass}, originalSink); } catch (Exception ignored) {}
            }
        }
        finish(code, result);
    }
}
