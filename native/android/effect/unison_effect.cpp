// SPDX-License-Identifier: Apache-2.0
// IEffect/FMQ 生命周期参考 AOSP hardware/interfaces/audio/aidl/default/EffectImpl.cpp。
// Copyright (C) 2022 The Android Open Source Project
#include <aidl/android/hardware/audio/effect/BnEffect.h>
#include <aidl/android/hardware/audio/effect/DefaultExtension.h>
#include <aidl/android/media/audio/common/PcmType.h>
#include <android/log.h>
#include <algorithm>
#include <atomic>
#include <cmath>
#include <chrono>
#include <mutex>
#include <optional>
#include <thread>
#include <vector>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/resource.h>
#include "fmq.h"
#include "tap_packet.h"

#if !defined(HAS_BINDER_SHELL_COMMAND) || !defined(__ANDROID_VENDOR__) || !defined(BINDER_STABILITY_SUPPORT)
#error "Unison Tap requires complete platform vendor Binder headers and conditions"
#endif
static_assert(std::is_same_v<std::string, std::__1::string>, "platform libc++ ABI required");

using namespace aidl::android::hardware::audio::effect;
using aidl::android::media::audio::common::AudioUuid;
using aidl::android::media::audio::common::AudioChannelLayout;
using aidl::android::media::audio::common::PcmType;
using ndk::ScopedAStatus;

namespace {
constexpr uint32_t kDataReady = 1u << 11; // AOSP IEffect V2 的 data MQ event
constexpr uint32_t kMqChanged = 1u << 10;
constexpr uint32_t kStatusNotFull = 0x01;
constexpr uint32_t kStatusNotEmpty = 0x02;
constexpr int kDelayParameter = 1;
constexpr int kMuteParameter = 2;
constexpr int kSystemGainParameter = 3;
constexpr int kClientMutedParameter = 4;
// AudioFlinger 交来的合成音量与 root 进程下发的系统增益各自异步更新；两者暂时对不上时，tap 比值最多保持这么久
// 等另一半到达，超时才认定是应用自己的音量变化。
constexpr int64_t kRatioSettleNs = 120'000'000;
constexpr float kRatioTolerance = 0.005f;
int64_t nowNs() { timespec t{}; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec * 1000000000LL + t.tv_nsec; }
AudioUuid typeUuid() { return {static_cast<int32_t>(0x8e2581c2), 0x3d9a, 0x4e15, 0xa77a, {0x61,0x7f,0x6f,0x9e,0x82,0x01}}; }
AudioUuid implUuid() { auto u = typeUuid(); u.node.back() = 2; return u; }
Descriptor buildDescriptor() {
    Descriptor d;
    d.common.id.type = typeUuid();
    d.common.id.uuid = implUuid();
    d.common.flags.type = Flags::Type::INSERT;
    d.common.flags.insert = Flags::Insert::LAST;
    // 音量控制者：AudioFlinger 不再把合成音量乘到会话上，改由本效果收下音量、在 tap 之后施加。
    d.common.flags.volume = Flags::Volume::CTRL;
    d.common.name = "Unison Tap";
    d.common.implementor = "Unison/6";
    return d;
}
ScopedAStatus error(const char* message) {
    __android_log_print(ANDROID_LOG_ERROR, "UnisonTap", "%s", message);
    return ScopedAStatus::fromExceptionCodeWithMessage(EX_ILLEGAL_ARGUMENT, message);
}
struct DelayLine {
    DelayLine(size_t samples, int64_t delay) : data(samples, 0.0f), microseconds(delay) {}
    std::vector<float> data;
    size_t position = 0;
    int64_t microseconds = 0;
    DelayLine* next = nullptr;
};
}

class UnisonEffect final : public BnEffect {
public:
    ~UnisonEffect() override { close(); }
    ScopedAStatus open(const Parameter::Common& common, const std::optional<Parameter::Specific>& specific,
                      IEffect::OpenEffectReturn* result) override {
        std::lock_guard lock(control_);
        if (state_ != State::INIT) return error("already open");
        __android_log_print(ANDROID_LOG_INFO, "UnisonTap", "open begin io=%d rate=%d frames=%lld",
            common.ioHandle, common.input.base.sampleRate, static_cast<long long>(common.input.frameCount));
        try {
            if (!valid(common)) return error("requires matching float stereo input/output");
            common_ = common;
            status_ = std::make_unique<Fmq<IEffect::Status>>(1, true);
            allocateData();
            socket_ = socket(AF_UNIX, SOCK_DGRAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
            if (socket_ < 0) __android_log_print(ANDROID_LOG_ERROR, "UnisonTap", "tap socket: %s", strerror(errno));
            // socket 失败不影响本机音频，tap 丢弃数会随 process 增长。
            streamId_ = static_cast<uint64_t>(nowNs());
            state_ = State::IDLE;
            if (specific) {
                auto p = Parameter::make<Parameter::specific>(*specific);
                auto s = parameter(p);
                if (!s.isOk()) return s;
            }
            descriptors(result);
            __android_log_print(ANDROID_LOG_INFO, "UnisonTap", "open V2 io=%d rate=%d batch=%lld",
                common.ioHandle, common.input.base.sampleRate, static_cast<long long>(common.input.frameCount));
            return ScopedAStatus::ok();
        } catch (const std::exception& e) { release(); return error(e.what()); }
    }
    ScopedAStatus close() override {
        std::lock_guard lock(control_);
        stopWorker();
        release();
        return ScopedAStatus::ok();
    }
    ScopedAStatus getDescriptor(Descriptor* result) override {
        try { *result = buildDescriptor(); return ScopedAStatus::ok(); }
        catch (...) { return error("descriptor allocation"); }
    }
    ScopedAStatus getState(State* result) override { *result = state_.load(); return ScopedAStatus::ok(); }
    ScopedAStatus command(CommandId id) override {
        std::lock_guard lock(control_);
        if (state_ == State::INIT) {
            if (id == CommandId::STOP || id == CommandId::RESET) return ScopedAStatus::ok();
            return error("not open");
        }
        if (id == CommandId::START) {
            if (state_ == State::PROCESSING) return ScopedAStatus::ok();
            quit_ = false;
            state_ = State::PROCESSING;
            gain_ = Gain{};
            try { worker_ = std::thread([this] { process(); }); }
            catch (...) { state_ = State::IDLE; return error("worker start"); }
        } else if (id == CommandId::STOP || id == CommandId::RESET) {
            stopWorker();
            input_->discard(); output_->discard(); status_->discard();
            if (activeDelay_) { std::fill(activeDelay_->data.begin(), activeDelay_->data.end(), 0); activeDelay_->position = 0; }
        } else return error("unknown command");
        return ScopedAStatus::ok();
    }
    ScopedAStatus setParameter(const Parameter& param) override {
        std::lock_guard lock(control_);
        try { return parameter(param); } catch (const std::exception& e) { return error(e.what()); }
    }
    ScopedAStatus getParameter(const Parameter::Id& id, Parameter* result) override {
        std::lock_guard lock(control_);
        try {
            if (id.getTag() == Parameter::Id::commonTag) {
                switch (id.get<Parameter::Id::commonTag>()) {
                    case Parameter::common: *result = Parameter::make<Parameter::common>(common_); return ScopedAStatus::ok();
                    case Parameter::volumeStereo: *result = Parameter::make<Parameter::volumeStereo>(Parameter::VolumeStereo{1,1}); return ScopedAStatus::ok();
                    default: return error("unsupported common getParameter");
                }
            }
            if (id.getTag() != Parameter::Id::vendorEffectTag) return error("unsupported getParameter");
            std::optional<DefaultExtension> blob;
            if (id.get<Parameter::Id::vendorEffectTag>().extension.getParcelable(&blob) != STATUS_OK || !blob || blob->bytes.size() < 16)
                return error("invalid parameter id");
            uint32_t key = 0;
            memcpy(&key, blob->bytes.data() + 12, 4);
            if (key != kDelayParameter && key != kMuteParameter) return error("unknown parameter");
            const bool delay = key == kDelayParameter;
            blob->bytes.resize(delay ? 24 : 20);
            const int32_t fields[] = {0, 4, delay ? 8 : 4, static_cast<int32_t>(key)};
            memcpy(blob->bytes.data(), fields, sizeof(fields));
            if (delay) { const int64_t value = delayUs_.load(); memcpy(blob->bytes.data() + 16, &value, 8); }
            else { const int32_t value = muted_.load() ? 1 : 0; memcpy(blob->bytes.data() + 16, &value, 4); }
            VendorExtension extension;
            extension.extension.setParcelable(*blob);
            *result = Parameter::make<Parameter::specific>(Parameter::Specific::make<Parameter::Specific::vendorEffect>(extension));
            return ScopedAStatus::ok();
        } catch (const std::exception& e) { return error(e.what()); }
    }
    ScopedAStatus reopen(IEffect::OpenEffectReturn* result) override {
        std::lock_guard lock(control_);
        try {
            if (state_ == State::INIT) return error("reopen before open");
            descriptors(result);
            return ScopedAStatus::ok();
        } catch (const std::exception& e) { return error(e.what()); }
    }
private:
    bool valid(const Parameter::Common& c) {
        const auto stereo = AudioChannelLayout::make<AudioChannelLayout::layoutMask>(AudioChannelLayout::LAYOUT_STEREO);
        return c.input.base.sampleRate > 0 && c.input.base.sampleRate == c.output.base.sampleRate &&
            c.input.base.format.pcm == PcmType::FLOAT_32_BIT && c.input.base.format == c.output.base.format &&
            c.input.base.channelMask == stereo && c.output.base.channelMask == stereo &&
            c.input.frameCount > 0 && c.output.frameCount > 0;
    }
    void allocateData() {
        const auto in = static_cast<size_t>(common_.input.frameCount) * 2;
        const auto out = static_cast<size_t>(common_.output.frameCount) * 2;
        auto input = std::make_unique<Fmq<float>>(in);
        auto output = std::make_unique<Fmq<float>>(out);
        std::vector<float> work(std::max(in, out)), tap(std::max(in, out));
        input_ = std::move(input);
        output_ = std::move(output);
        work_.swap(work);
        tap_.swap(tap);
    }
    void descriptors(IEffect::OpenEffectReturn* result) {
        result->statusMQ = status_->descriptor();
        result->inputDataMQ = input_->descriptor();
        result->outputDataMQ = output_->descriptor();
    }
    void collectRetired() {
        auto* p = retired_.exchange(nullptr);
        while (p) { auto* next = p->next; delete p; p = next; }
    }
    void scheduleDelay(int64_t us) {
        if (us < 0) throw std::invalid_argument("negative local delay");
        const uint64_t rate = static_cast<uint64_t>(common_.input.base.sampleRate);
        if (uint64_t(us) / 1000000 > SIZE_MAX / (2 * sizeof(float)) / rate) throw std::invalid_argument("delay size overflow");
        const uint64_t frames = uint64_t(us) / 1000000 * rate + uint64_t(us) % 1000000 * rate / 1000000;
        if (frames > SIZE_MAX / (2 * sizeof(float))) throw std::invalid_argument("delay size overflow");
        // 分配和回收只在 Binder 控制线程进行，process 只交换指针。
        auto next = std::make_unique<DelayLine>(static_cast<size_t>(frames) * 2, us);
        delete pending_.exchange(next.release());
        delayUs_ = us;
        collectRetired();
    }
    ScopedAStatus parameter(const Parameter& param) {
        __android_log_print(ANDROID_LOG_DEBUG, "UnisonTap", "setParameter tag=%d state=%d",
            static_cast<int>(param.getTag()), static_cast<int>(state_.load()));
        // 音量可在 open 前到达；设备/模式等 indication 不消费。
        if (param.getTag() == Parameter::volumeStereo) {
            const auto& volume = param.get<Parameter::volumeStereo>();
            // 合成音量不会超过 1；超出时按 1，不放大。
            volumeLeft_ = std::clamp(volume.left, 0.0f, 1.0f);
            volumeRight_ = std::clamp(volume.right, 0.0f, 1.0f);
            return ScopedAStatus::ok();
        }
        if (param.getTag() != Parameter::common && param.getTag() != Parameter::specific) return ScopedAStatus::ok();
        if (state_ == State::INIT) return error("parameter before open");
        if (param.getTag() == Parameter::common) {
            const auto& c = param.get<Parameter::common>();
            if (!valid(c)) return error("unsupported common format");
            if (c.input != common_.input || c.output != common_.output) {
                const bool resume = state_ == State::PROCESSING;
                stopWorker();
                common_ = c;
                allocateData();
                scheduleDelay(delayUs_);
                streamId_ = static_cast<uint64_t>(nowNs()); frames_ = 0;
                status_->wake(kMqChanged);
                if (resume) { quit_ = false; state_ = State::PROCESSING; gain_ = Gain{}; worker_ = std::thread([this] { process(); }); }
            }
            return ScopedAStatus::ok();
        }
        if (param.getTag() != Parameter::specific) return ScopedAStatus::ok();
        const auto& specific = param.get<Parameter::specific>();
        if (specific.getTag() != Parameter::Specific::vendorEffect) return error("unsupported parameter");
        std::optional<DefaultExtension> blob;
        if (specific.get<Parameter::Specific::vendorEffect>().extension.getParcelable(&blob) != STATUS_OK || !blob || blob->bytes.size() < 20)
            return error("invalid vendor parameter");
        int32_t fields[4]; memcpy(fields, blob->bytes.data(), sizeof(fields));
        if (fields[1] != 4) return error("invalid vendor parameter size");
        if (fields[3] == kDelayParameter && fields[2] == 8 && blob->bytes.size() >= 24) {
            int64_t us; memcpy(&us, blob->bytes.data() + 16, 8); scheduleDelay(us);
        } else if (fields[3] == kMuteParameter && fields[2] == 4) {
            int32_t value; memcpy(&value, blob->bytes.data() + 16, 4); muted_ = value != 0;
        } else if (fields[3] == kSystemGainParameter && fields[2] == 4) {
            float value; memcpy(&value, blob->bytes.data() + 16, 4);
            if (std::isnan(value) || value > 1.0f) return error("invalid system gain");
            systemGain_ = value < 0 ? -1.0f : value;
        } else if (fields[3] == kClientMutedParameter && fields[2] == 4) {
            int32_t value; memcpy(&value, blob->bytes.data() + 16, 4); clientMuted_ = value != 0;
        } else return error("unknown vendor parameter");
        return ScopedAStatus::ok();
    }
    /**
     * tap 增益 = V 中属于应用的部分 = V ÷ S，按声道计算并钳到 1，绝不放大。V 与 S 各自异步更新：比值偏离已确认值时
     * 先保持原值，另一半在 kRatioSettleNs 内到达、比值恢复时不变；超时才采用新比值（应用自己的音量变化），
     * 此后 kRatioSettleNs 内的继续变化直接跟随。
     * V 降到 0 立即跟随（暂停渐弱、应用静音）。S 为 0 时无法推算，沿用已确认的比值（本实例还没有时按 1），
     * 应用报告静音时为 0。
     */
    void tapTarget(const float volume[2], int64_t now, float target[2]) {
        const float system = systemGain_.load();
        if (system > 0 && gain_.lastSystem == 0) gain_.systemRaisedNs = now;
        gain_.lastSystem = system;
        if (system < 0) {
            for (int c = 0; c < 2; ++c) target[c] = volume[c];
            return;
        }
        if (system == 0) {
            const bool muted = clientMuted_.load();
            for (int c = 0; c < 2; ++c) target[c] = muted ? 0.0f : gain_.haveStable ? gain_.stable[c] : 1.0f;
            return;
        }
        if (volume[0] == 0 && volume[1] == 0) {
            // V 为 0 不反映比值（暂停、应用静音或系统音量正降到 0），保留已确认的比值。S 刚从 0 升起而 V 尚未跟上时
            // 照旧输出，否则立即跟随到 0。
            const bool pending = gain_.haveStable && now - gain_.systemRaisedNs < kRatioSettleNs;
            for (int c = 0; c < 2; ++c) target[c] = pending ? gain_.stable[c] : 0.0f;
            return;
        }
        float candidate[2];
        bool matches = true;
        for (int c = 0; c < 2; ++c) {
            candidate[c] = std::min(1.0f, volume[c] / system);
            if (std::abs(candidate[c] - gain_.stable[c]) > kRatioTolerance * std::max(gain_.stable[c], 0.01f)) matches = false;
        }
        if (!gain_.haveStable || matches) {
            for (int c = 0; c < 2; ++c) target[c] = gain_.stable[c] = candidate[c];
            gain_.haveStable = true;
            gain_.deviationNs = 0;
            return;
        }
        if (!gain_.deviationNs) gain_.deviationNs = now;
        // 确认是应用的音量变化后，紧接着的连续变化（淡入淡出）直接跟随，不再逐段等待。
        if (now - gain_.deviationNs >= kRatioSettleNs || now < gain_.followUntilNs) {
            for (int c = 0; c < 2; ++c) gain_.stable[c] = candidate[c];
            gain_.deviationNs = 0;
            gain_.followUntilNs = now + kRatioSettleNs;
        }
        for (int c = 0; c < 2; ++c) target[c] = gain_.stable[c];
    }
    void stopWorker() {
        quit_ = true;
        if (status_) status_->wake(kDataReady | kStatusNotFull);
        if (worker_.joinable()) worker_.join();
        if (state_ != State::INIT) state_ = State::IDLE;
    }
    void release() {
        input_.reset(); output_.reset(); status_.reset(); work_.clear(); tap_.clear();
        if (socket_ >= 0) ::close(socket_);
        socket_ = -1;
        delete activeDelay_; activeDelay_ = nullptr;
        delete pending_.exchange(nullptr);
        collectRetired();
        state_ = State::INIT;
        frames_ = 0; droppedFrames_ = 0; droppedBatches_ = 0; delayUs_ = 0;
        muted_ = false;
        volumeLeft_ = 0; volumeRight_ = 0; systemGain_ = -1; clientMuted_ = false;
    }
    void process() noexcept {
        if (setpriority(PRIO_PROCESS, 0, -16) != 0)
            __android_log_print(ANDROID_LOG_WARN, "UnisonTap", "cannot raise worker priority: %s", strerror(errno));
        sockaddr_un destination{};
        destination.sun_family = AF_UNIX;
        memcpy(destination.sun_path + 1, UNISON_TAP_SOCKET, sizeof(UNISON_TAP_SOCKET) - 1);
        const auto addressSize = offsetof(sockaddr_un, sun_path) + sizeof(UNISON_TAP_SOCKET);
        while (status_->wait(kDataReady, quit_)) {
            const int64_t callNs = nowNs();
            size_t n = std::min({input_->available(), output_->space(), work_.size()}) & ~size_t(1);
            if (!n || !input_->read(work_.data(), n)) continue;
            if (auto* next = pending_.exchange(nullptr)) {
                if (activeDelay_) {
                    auto* previous = retired_.load();
                    do { activeDelay_->next = previous; } while (!retired_.compare_exchange_weak(previous, activeDelay_));
                }
                activeDelay_ = next;
            }
            const auto frames = static_cast<uint32_t>(n / 2);
            const float volume[2] = {volumeLeft_.load(), volumeRight_.load()};
            float tapGain[2];
            tapTarget(volume, callNs, tapGain);
            if (!gain_.started) {
                // 开始处理前收到的音量直接生效；之后每批从上一批的增益线性过渡，与混音器的音量渐变相同。
                for (int c = 0; c < 2; ++c) { gain_.local[c] = volume[c]; gain_.tap[c] = tapGain[c]; }
                gain_.started = true;
            }
            for (uint32_t f = 0; f < frames; ++f) {
                const float k = static_cast<float>(f + 1) / static_cast<float>(frames);
                for (int c = 0; c < 2; ++c) {
                    const float x = work_[2 * f + c];
                    tap_[2 * f + c] = x * (gain_.tap[c] + (tapGain[c] - gain_.tap[c]) * k);
                    work_[2 * f + c] = x * (gain_.local[c] + (volume[c] - gain_.local[c]) * k);
                }
            }
            for (int c = 0; c < 2; ++c) { gain_.local[c] = volume[c]; gain_.tap[c] = tapGain[c]; }
            UnisonTapHeader header{UNISON_TAP_MAGIC, static_cast<uint32_t>(common_.input.base.sampleRate), frames,
                common_.ioHandle, streamId_, frames_, callNs, droppedFrames_, droppedBatches_, activeDelay_ ? static_cast<int32_t>(activeDelay_->microseconds / 1000) : 0, common_.session};
            iovec vectors[] = {{&header, sizeof(header)}, {tap_.data(), n * sizeof(float)}};
            msghdr message{};
            message.msg_name = &destination; message.msg_namelen = addressSize;
            message.msg_iov = vectors; message.msg_iovlen = 2;
            const ssize_t sent = socket_ < 0 ? -1 : sendmsg(socket_, &message, MSG_DONTWAIT | MSG_NOSIGNAL);
            if (sent != static_cast<ssize_t>(sizeof(header) + n * sizeof(float))) { droppedFrames_ += frames; ++droppedBatches_; }
            frames_ += frames;
            // 本机输出：音量在延迟线之前施加，音量变化被听到的时刻与原先由混音器施加时相同。零延迟时直接保持原样。
            if (activeDelay_ && !activeDelay_->data.empty()) {
                auto& line = *activeDelay_;
                for (size_t i = 0; i < n; ++i) {
                    std::swap(work_[i], line.data[line.position]);
                    if (++line.position == line.data.size()) line.position = 0;
                }
            }
            // 静音在 tap 与延迟线之后，仍连续处理和上报同样的帧。
            if (muted_.load()) std::fill_n(work_.data(), n, 0.0f);
            output_->write(work_.data(), n);
            const IEffect::Status result{0, static_cast<int32_t>(n), static_cast<int32_t>(n)};
            // audioserver 先写 input/wake data-ready，再 readBlocking(status)，最后读 output。
            // 对应 AOSP writeBlocking：满时等 0x01；先发布状态，再唤醒 0x02。
            if (!status_->writeBlocking(&result, 1, kStatusNotFull, kStatusNotEmpty, quit_)) return;
        }
    }
    std::mutex control_;
    Parameter::Common common_;
    std::atomic<State> state_{State::INIT};
    std::atomic<bool> quit_{false};
    std::thread worker_;
    std::unique_ptr<Fmq<IEffect::Status>> status_;
    std::unique_ptr<Fmq<float>> input_, output_;
    std::vector<float> work_, tap_;
    int socket_ = -1;
    uint64_t streamId_ = 0, frames_ = 0, droppedFrames_ = 0, droppedBatches_ = 0;
    std::atomic<int64_t> delayUs_{0};
    std::atomic<bool> muted_{false};
    // AudioFlinger 交来的合成音量 V（主音量 × 系统音量 × 应用给轨道的音量 × VolumeShaper），收到前按 0。
    std::atomic<float> volumeLeft_{0}, volumeRight_{0};
    // root 进程下发的系统部分 S；负数表示未知，此时 tap 与本机一样按 V 衰减。
    std::atomic<float> systemGain_{-1};
    // 播放配置报告的应用自己静音（客户端音量或 VolumeShaper 为 0）；只在 S 为 0、无法从 V 推算时使用。
    std::atomic<bool> clientMuted_{false};
    struct Gain {
        float local[2]{};
        float tap[2]{};
        float stable[2]{};
        bool started = false;
        bool haveStable = false;
        int64_t deviationNs = 0;
        int64_t followUntilNs = 0;
        int64_t systemRaisedNs = INT64_MIN / 2;
        float lastSystem = -1;
    };
    Gain gain_; // 只在 worker 中访问；START 前由控制线程重置
    std::atomic<DelayLine*> pending_{nullptr}, retired_{nullptr};
    DelayLine* activeDelay_ = nullptr;
};

extern "C" __attribute__((visibility("default"))) binder_exception_t queryEffect(const AudioUuid* uuid, Descriptor* result) {
    if (!uuid || !result) return EX_ILLEGAL_ARGUMENT;
    try { if (*uuid != implUuid()) return EX_ILLEGAL_ARGUMENT; *result = buildDescriptor(); return EX_NONE; }
    catch (...) { return EX_ILLEGAL_STATE; }
}
extern "C" __attribute__((visibility("default"))) binder_exception_t createEffect(const AudioUuid* uuid, std::shared_ptr<IEffect>* result) {
    if (!uuid || !result) return EX_ILLEGAL_ARGUMENT;
    try {
        if (*uuid != implUuid()) return EX_ILLEGAL_ARGUMENT;
        // 设备共享绑定负责创建及标记 Binder，Factory::fromBinder 也使用同一 Binder class。
        *result = ndk::SharedRefBase::make<UnisonEffect>();
        return EX_NONE;
    }
    catch (...) { return EX_ILLEGAL_STATE; }
}
extern "C" __attribute__((visibility("default"))) binder_exception_t destroyEffect(const std::shared_ptr<IEffect>& instance) {
    if (!instance) return EX_ILLEGAL_ARGUMENT;
    return instance->close().isOk() ? EX_NONE : EX_ILLEGAL_STATE;
}
