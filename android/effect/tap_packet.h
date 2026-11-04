#pragma once
#include <stdint.h>

// 仅 HAL → root 进程的本机报文；外部 UDP 协议保持不变。arm64 小端序。
#define UNISON_TAP_SOCKET "unison.tap"
#define UNISON_TAP_MAGIC 0x31585455u
struct UnisonTapHeader {
    uint32_t magic;
    uint32_t sampleRate;
    uint32_t frames;
    int32_t ioHandle;
    uint64_t streamId;
    uint64_t firstFrame;
    int64_t callTimeNs;
    uint64_t droppedFrames;
    uint64_t droppedBatches;
    int32_t localDelayMs;
    uint32_t reserved;
};
#ifdef __cplusplus
static_assert(sizeof(UnisonTapHeader) == 64);
#endif
