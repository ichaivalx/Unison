// SPDX-License-Identifier: Apache-2.0
// FMQ 布局和字节计数算法参考 AOSP system/libfmq/include/fmq/MessageQueueBase.h。
// Copyright (C) 2015 The Android Open Source Project
#pragma once
#include <aidl/android/hardware/common/fmq/MQDescriptor.h>
#include <aidl/android/hardware/common/fmq/SynchronizedReadWrite.h>
#include <algorithm>
#include <atomic>
#include <cstring>
#include <stdexcept>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <linux/futex.h>
#include <climits>
#include <unistd.h>
#include <android/log.h>
#include <cerrno>

extern "C" int ashmem_create_region(const char* name, size_t size);

template<class T> class Fmq {
public:
    using Descriptor = aidl::android::hardware::common::fmq::MQDescriptor<
        T, aidl::android::hardware::common::fmq::SynchronizedReadWrite>;
    explicit Fmq(size_t count, bool event = false) : bytes_(count * sizeof(T)) {
        const size_t page = static_cast<size_t>(getpagesize());
        eventOffset_ = (16 + bytes_ + 7) & ~size_t(7);
        size_ = (eventOffset_ + (event ? 4 : 0) + page - 1) / page * page;
        fd_ = memfd_create("unison-fmq", MFD_CLOEXEC);
        if (fd_ < 0) {
            __android_log_print(ANDROID_LOG_WARN, "UnisonTap", "FMQ memfd_create: %s", strerror(errno));
        } else if (ftruncate(fd_, size_) != 0) {
            const int failure = errno;
            ::close(fd_); fd_ = -1;
            __android_log_print(ANDROID_LOG_WARN, "UnisonTap", "FMQ memfd ftruncate: %s", strerror(failure));
        }
        if (fd_ < 0) {
            // 使用 HAL 已在使用的 libcutils 分配器，遵循该设备 ashmem/memfd 选择。
            fd_ = ashmem_create_region("unison-fmq", size_);
            if (fd_ < 0) throw std::runtime_error(std::string("FMQ platform ashmem: ") + strerror(errno));
            __android_log_print(ANDROID_LOG_INFO, "UnisonTap", "FMQ allocator=platform size=%zu", size_);
        }
        base_ = static_cast<uint8_t*>(mmap(nullptr, size_, PROT_READ | PROT_WRITE, MAP_SHARED, fd_, 0));
        if (base_ == MAP_FAILED) { const int failure = errno; ::close(fd_); base_ = nullptr; throw std::runtime_error(std::string("FMQ mmap: ") + strerror(failure)); }
        read_ = new (base_) std::atomic<uint64_t>(0);
        write_ = new (base_ + 8) std::atomic<uint64_t>(0);
        if (event) event_ = new (base_ + eventOffset_) std::atomic<uint32_t>(0);
    }
    ~Fmq() { if (base_) munmap(base_, size_); if (fd_ >= 0) ::close(fd_); }
    Fmq(const Fmq&) = delete;
    Fmq& operator=(const Fmq&) = delete;
    size_t available() const {
        const uint64_t n = write_->load(std::memory_order_acquire) - read_->load(std::memory_order_acquire);
        return n <= bytes_ ? n / sizeof(T) : 0;
    }
    size_t space() const { return bytes_ / sizeof(T) - available(); }
    bool read(T* data, size_t n) {
        if (n > available()) return false;
        const uint64_t r = read_->load(std::memory_order_relaxed);
        copy(data, base_ + 16, r, n, false);
        read_->store(r + n * sizeof(T), std::memory_order_release);
        return true;
    }
    bool write(const T* data, size_t n) {
        if (n > space()) return false;
        const uint64_t w = write_->load(std::memory_order_relaxed);
        copy(const_cast<T*>(data), base_ + 16, w, n, true);
        write_->store(w + n * sizeof(T), std::memory_order_release);
        return true;
    }
    void discard() { read_->store(write_->load(std::memory_order_acquire), std::memory_order_release); }
    Descriptor descriptor() const {
        Descriptor d;
        d.quantum = sizeof(T);
        d.flags = 1; // kSynchronizedReadWrite
        using Grantor = aidl::android::hardware::common::fmq::GrantorDescriptor;
        d.grantors = {Grantor{0, 0, 8}, Grantor{0, 8, 8}, Grantor{0, 16, static_cast<int64_t>(bytes_)}};
        if (event_) d.grantors.push_back(Grantor{0, static_cast<int32_t>(eventOffset_), 4});
        d.handle.fds.emplace_back(dup(fd_));
        return d;
    }
    void wake(uint32_t bits) {
        event_->fetch_or(bits, std::memory_order_release);
        // 共享映射的 EventFlag 必须用跨进程 futex，不能用 FUTEX_*_PRIVATE。
        syscall(SYS_futex, event_, FUTEX_WAKE, INT_MAX, nullptr, nullptr, 0);
    }
    bool writeBlocking(const T* data, size_t n, uint32_t notFull, uint32_t notEmpty,
                       const std::atomic<bool>& quit) {
        while (!quit.load(std::memory_order_acquire)) {
            if (write(data, n)) { wake(notEmpty); return true; }
            if (!wait(notFull, quit)) return false;
        }
        return false;
    }
    bool wait(uint32_t bits, const std::atomic<bool>& quit) {
        while (!quit.load(std::memory_order_acquire)) {
            uint32_t value = event_->load(std::memory_order_acquire);
            if (value & bits) {
                if (event_->compare_exchange_weak(value, value & ~bits, std::memory_order_acq_rel)) return true;
                continue;
            }
            syscall(SYS_futex, event_, FUTEX_WAIT, value, nullptr, nullptr, 0);
        }
        return false;
    }
private:
    void copy(T* data, uint8_t* ring, uint64_t position, size_t n, bool writing) {
        const size_t offset = position % bytes_;
        const size_t total = n * sizeof(T);
        const size_t first = std::min(total, bytes_ - offset);
        auto* p = reinterpret_cast<uint8_t*>(data);
        if (writing) { memcpy(ring + offset, p, first); memcpy(ring, p + first, total - first); }
        else { memcpy(p, ring + offset, first); memcpy(p + first, ring, total - first); }
    }
    int fd_ = -1;
    uint8_t* base_ = nullptr;
    size_t bytes_, size_ = 0, eventOffset_ = 0;
    std::atomic<uint64_t>* read_ = nullptr;
    std::atomic<uint64_t>* write_ = nullptr;
    std::atomic<uint32_t>* event_ = nullptr;
};
