// SPDX-License-Identifier: Apache-2.0
// IEffect/FMQ 生命周期参考 AOSP hardware/interfaces/audio/aidl/default/EffectImpl.cpp。
// Copyright (C) 2022 The Android Open Source Project
#include <aidl/android/hardware/audio/effect/BnEffect.h>
#include <aidl/android/hardware/audio/effect/DefaultExtension.h>
#include <aidl/android/media/audio/common/PcmType.h>
#include <android/log.h>
#include <atomic>
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
int64_t nowNs() { timespec t{}; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec * 1000000000LL + t.tv_nsec; }
AudioUuid typeUuid() { return {static_cast<int32_t>(0x8e2581c2), 0x3d9a, 0x4e15, static_cast<int16_t>(0xa77a), {0x61,0x7f,0x6f,0x9e,0x82,0x01}}; }
AudioUuid implUuid() { auto u = typeUuid(); u.node.back() = 2; return u; }
Descriptor buildDescriptor() {
    Descriptor d;
    d.common.id.type = typeUuid();
    d.common.id.uuid = implUuid();
    d.common.flags.type = Flags::Type::INSERT;
    d.common.flags.insert = Flags::Insert::LAST;
    d.common.name = "Unison Tap";
    d.common.implementor = "Unison";
    return d;
}
ScopedAStatus error(const char* message) {
    __android_log_print(ANDROID_LOG_ERROR, "UnisonTap", "%s", message);
    return ScopedAStatus::fromExceptionCodeWithMessage(EX_ILLEGAL_ARGUMENT, message);
}
struct DelayLine {
    DelayLine(size_t samples, int32_t delay) : data(samples, 0.0f), milliseconds(delay) {}
    std::vector<float> data;
    size_t position = 0;
    int32_t milliseconds = 0;
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
        if (state_ == State::INIT) return error("not open");
        if (id == CommandId::START) {
            if (state_ == State::PROCESSING) return ScopedAStatus::ok();
            quit_ = false;
            state_ = State::PROCESSING;
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
            if (key != kDelayParameter) return error("unknown parameter");
            blob->bytes.resize(20);
            const int32_t values[] = {0, 4, 4, kDelayParameter, delayMs_.load()};
            memcpy(blob->bytes.data(), values, sizeof(values));
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
        std::vector<float> work(std::max(in, out));
        input_ = std::move(input);
        output_ = std::move(output);
        work_.swap(work);
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
    void scheduleDelay(int32_t ms) {
        if (ms < 0) throw std::invalid_argument("negative local delay");
        const uint64_t frames = uint64_t(common_.input.base.sampleRate) * uint64_t(ms) / 1000;
        if (frames > SIZE_MAX / (2 * sizeof(float))) throw std::invalid_argument("delay size overflow");
        // 分配和回收只在 Binder 控制线程进行，process 只交换指针。
        auto next = std::make_unique<DelayLine>(static_cast<size_t>(frames) * 2, ms);
        delete pending_.exchange(next.release());
        delayMs_ = ms;
        collectRetired();
    }
    ScopedAStatus parameter(const Parameter& param) {
        if (state_ == State::INIT) return error("parameter before open");
        if (param.getTag() == Parameter::common) {
            const auto& c = param.get<Parameter::common>();
            if (!valid(c)) return error("unsupported common format");
            if (c.input != common_.input || c.output != common_.output) {
                const bool resume = state_ == State::PROCESSING;
                stopWorker();
                common_ = c;
                allocateData();
                scheduleDelay(delayMs_);
                streamId_ = static_cast<uint64_t>(nowNs()); frames_ = 0;
                status_->wake(kMqChanged);
                if (resume) { quit_ = false; state_ = State::PROCESSING; worker_ = std::thread([this] { process(); }); }
            }
            return ScopedAStatus::ok();
        }
        if (param.getTag() != Parameter::specific) return ScopedAStatus::ok();
        const auto& specific = param.get<Parameter::specific>();
        if (specific.getTag() != Parameter::Specific::vendorEffect) return error("unsupported parameter");
        std::optional<DefaultExtension> blob;
        if (specific.get<Parameter::Specific::vendorEffect>().extension.getParcelable(&blob) != STATUS_OK || !blob || blob->bytes.size() < 20)
            return error("invalid vendor parameter");
        int32_t fields[5]; memcpy(fields, blob->bytes.data(), sizeof(fields));
        if (fields[1] != 4 || fields[2] != 4 || fields[3] != kDelayParameter) return error("unknown vendor parameter");
        scheduleDelay(fields[4]);
        return ScopedAStatus::ok();
    }
    void stopWorker() {
        quit_ = true;
        if (status_) status_->wake(kDataReady | kStatusNotFull);
        if (worker_.joinable()) worker_.join();
        if (state_ != State::INIT) state_ = State::IDLE;
    }
    void release() {
        input_.reset(); output_.reset(); status_.reset(); work_.clear();
        if (socket_ >= 0) ::close(socket_);
        socket_ = -1;
        delete activeDelay_; activeDelay_ = nullptr;
        delete pending_.exchange(nullptr);
        collectRetired();
        state_ = State::INIT;
        frames_ = 0; droppedFrames_ = 0; droppedBatches_ = 0; delayMs_ = 0;
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
            UnisonTapHeader header{UNISON_TAP_MAGIC, static_cast<uint32_t>(common_.input.base.sampleRate), frames,
                common_.ioHandle, streamId_, frames_, callNs, droppedFrames_, droppedBatches_, activeDelay_ ? activeDelay_->milliseconds : 0, 0};
            iovec vectors[] = {{&header, sizeof(header)}, {work_.data(), n * sizeof(float)}};
            msghdr message{};
            message.msg_name = &destination; message.msg_namelen = addressSize;
            message.msg_iov = vectors; message.msg_iovlen = 2;
            const ssize_t sent = socket_ < 0 ? -1 : sendmsg(socket_, &message, MSG_DONTWAIT | MSG_NOSIGNAL);
            if (sent != static_cast<ssize_t>(sizeof(header) + n * sizeof(float))) { droppedFrames_ += frames; ++droppedBatches_; }
            frames_ += frames;
            // tap 始终位于本机延迟线之前。零延迟时直接保持原样。
            if (activeDelay_ && !activeDelay_->data.empty()) {
                auto& line = *activeDelay_;
                for (size_t i = 0; i < n; ++i) {
                    std::swap(work_[i], line.data[line.position]);
                    if (++line.position == line.data.size()) line.position = 0;
                }
            }
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
    std::vector<float> work_;
    int socket_ = -1;
    uint64_t streamId_ = 0, frames_ = 0, droppedFrames_ = 0, droppedBatches_ = 0;
    std::atomic<int32_t> delayMs_{0};
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
