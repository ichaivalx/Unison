#include "unison/receiver.h"

#include <aaudio/AAudio.h>
#include <jni.h>
#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <mutex>
#include <thread>
#include <time.h>

namespace {
class AndroidReceiver {
public:
    unison::Receiver receiver;

    bool start() {
        std::lock_guard<std::mutex> lock(lifecycle);
        if (active.load()) return true;
        if (!receiver.start()) return false;
        rebuild.store(false);
        active.store(true);
        if (!openStream()) {
            active.store(false);
            receiver.stop();
            return false;
        }
        manager = std::thread([this] {
            while (active.load()) {
                if (rebuild.exchange(false)) closeStream();
                if (!stream) openStream();
                if (stream) {
                    int64_t frame = 0, timeNs = 0;
                    auto result = AAudioStream_getTimestamp(stream, CLOCK_MONOTONIC, &frame, &timeNs);
                    {
                        std::lock_guard<std::mutex> guard(timestampMutex);
                        stampValid = result == AAUDIO_OK;
                        stampFrame = frame;
                        stampTimeNs = timeNs;
                    }
                    xruns.store(AAudioStream_getXRunCount(stream));
                }
                std::unique_lock<std::mutex> guard(waitMutex);
                wake.wait_for(guard, std::chrono::milliseconds(stream ? 10 : 500), [this] {
                    return !active.load() || rebuild.load();
                });
            }
            closeStream();
        });
        return true;
    }

    void stop() {
        std::lock_guard<std::mutex> lock(lifecycle);
        active.store(false);
        wake.notify_all();
        if (manager.joinable()) manager.join();
        receiver.stop();
    }

    void routeChanged() {
        rebuild.store(true);
        wake.notify_all();
    }

    std::string stats() {
        std::string json = receiver.statsJson();
        json.pop_back();
        return json + ",\"outputOpen\":" + (outputOpen.load() ? "true" : "false") +
            ",\"outputRate\":" + std::to_string(outputRate.load()) +
            ",\"underruns\":" + std::to_string(xruns.load()) + "}";
    }

private:
    std::mutex lifecycle, timestampMutex, waitMutex;
    std::condition_variable wake;
    std::thread manager;
    std::atomic<bool> active{false}, rebuild{false}, outputOpen{false};
    std::atomic<int> outputRate{0}, xruns{0};
    AAudioStream* stream = nullptr;
    bool stampValid = false;
    int64_t stampFrame = 0, stampTimeNs = 0;

    static aaudio_data_callback_result_t audioCallback(AAudioStream* stream, void* user,
                                                       void* audio, int32_t frames) {
        auto& self = *static_cast<AndroidReceiver*>(user);
        int rate = AAudioStream_getSampleRate(stream);
        int64_t written = AAudioStream_getFramesWritten(stream);
        int64_t now = unison::monotonicUs();
        int64_t firstFrameUs;
        bool real;
        {
            std::lock_guard<std::mutex> lock(self.timestampMutex);
            real = self.stampValid && now - self.stampTimeNs / 1000 < 100'000;
            if (real) {
                firstFrameUs = self.stampTimeNs / 1000 +
                    static_cast<int64_t>((written - self.stampFrame) * 1e6 / rate);
            } else {
                int64_t queued = std::max<int64_t>(0, written - AAudioStream_getFramesRead(stream));
                queued = std::max<int64_t>(queued, AAudioStream_getBufferSizeInFrames(stream));
                firstFrameUs = now + static_cast<int64_t>(queued * 1e6 / rate);
            }
        }
        self.receiver.render(static_cast<float*>(audio), frames, rate, firstFrameUs, real);
        return AAUDIO_CALLBACK_RESULT_CONTINUE;
    }

    static void errorCallback(AAudioStream*, void* user, aaudio_result_t) {
        static_cast<AndroidReceiver*>(user)->routeChanged();
    }

    bool openStream() {
        {
            std::lock_guard<std::mutex> lock(timestampMutex);
            stampValid = false;
        }
        AAudioStreamBuilder* builder = nullptr;
        if (AAudio_createStreamBuilder(&builder) != AAUDIO_OK) return false;
        AAudioStreamBuilder_setDirection(builder, AAUDIO_DIRECTION_OUTPUT);
        AAudioStreamBuilder_setPerformanceMode(builder, AAUDIO_PERFORMANCE_MODE_LOW_LATENCY);
        AAudioStreamBuilder_setSharingMode(builder, AAUDIO_SHARING_MODE_SHARED);
        AAudioStreamBuilder_setFormat(builder, AAUDIO_FORMAT_PCM_FLOAT);
        AAudioStreamBuilder_setChannelCount(builder, 2);
        AAudioStreamBuilder_setUsage(builder, AAUDIO_USAGE_MEDIA);
        AAudioStreamBuilder_setContentType(builder, AAUDIO_CONTENT_TYPE_MUSIC);
        AAudioStreamBuilder_setSpatializationBehavior(builder, AAUDIO_SPATIALIZATION_BEHAVIOR_NEVER);
        AAudioStreamBuilder_setDataCallback(builder, audioCallback, this);
        AAudioStreamBuilder_setErrorCallback(builder, errorCallback, this);
        auto result = AAudioStreamBuilder_openStream(builder, &stream);
        AAudioStreamBuilder_delete(builder);
        if (result != AAUDIO_OK) { stream = nullptr; return false; }
        if (AAudioStream_getFormat(stream) != AAUDIO_FORMAT_PCM_FLOAT ||
            AAudioStream_getChannelCount(stream) != 2) {
            closeStream();
            return false;
        }
        AAudioStream_setBufferSizeInFrames(stream, AAudioStream_getFramesPerBurst(stream) * 2);
        outputRate.store(AAudioStream_getSampleRate(stream));
        if (AAudioStream_requestStart(stream) != AAUDIO_OK) {
            closeStream();
            return false;
        }
        outputOpen.store(true);
        return true;
    }

    void closeStream() {
        outputOpen.store(false);
        if (stream) {
            AAudioStream_requestStop(stream);
            AAudioStream_close(stream);
            stream = nullptr;
        }
        std::lock_guard<std::mutex> lock(timestampMutex);
        stampValid = false;
    }
};

AndroidReceiver engine;
}  // namespace

extern "C" JNIEXPORT jboolean JNICALL
Java_io_github_ichaivalx_unison_ReceiverEngine_start(JNIEnv*, jobject) {
    return engine.start() ? JNI_TRUE : JNI_FALSE;
}
extern "C" JNIEXPORT void JNICALL
Java_io_github_ichaivalx_unison_ReceiverEngine_stop(JNIEnv*, jobject) { engine.stop(); }
extern "C" JNIEXPORT void JNICALL
Java_io_github_ichaivalx_unison_ReceiverEngine_setOffsetMs(JNIEnv*, jobject, jfloat ms) {
    engine.receiver.setOffsetMs(ms);
}
extern "C" JNIEXPORT jstring JNICALL
Java_io_github_ichaivalx_unison_ReceiverEngine_statsJson(JNIEnv* env, jobject) {
    return env->NewStringUTF(engine.stats().c_str());
}
extern "C" JNIEXPORT void JNICALL
Java_io_github_ichaivalx_unison_ReceiverEngine_routeChanged(JNIEnv*, jobject) { engine.routeChanged(); }
