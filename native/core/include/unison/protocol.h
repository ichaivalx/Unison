// Unison 网络协议（原型）。音源端（Android root 进程，Kotlin）与接收端（C++）共同遵守。
//
// 全部为 UDP，小端序。每个报文以 8 字节报头开始：
//   u32 magic = 0x4E534E55（字节序列 'U' 'N' 'S' 'N'）
//   u8  version = 1
//   u8  type
//   u16 reserved = 0
//
// 时钟：音源时钟为音源设备的 CLOCK_MONOTONIC，单位微秒（Java 中 System.nanoTime() / 1000）。
// 接收端用自己的单调时钟（Android CLOCK_MONOTONIC，Windows QPC），通过 PING/PONG 估计与音源时钟的差值。
//
// 端口：音源在 kSourcePort 上收发全部控制与音频报文；音源每秒向 kBeaconPort 广播 BEACON。
// 接收端用同一个 UDP 套接字发送 SUBSCRIBE/PING 并接收 AUDIO/PONG。
//
// 报文（报头之后的负载）：
//   BEACON    音源 → 广播:kBeaconPort，每秒一次
//             u16 sourcePort, u16 nameLen, u8[nameLen] name(UTF-8)
//   SUBSCRIBE 接收端 → 音源:kSourcePort，每秒一次；音源对最近 5 秒内订阅过的 (ip,port) 发送 AUDIO
//             u64 receiverId, u16 nameLen, u8[nameLen] name(UTF-8)
//   PING      接收端 → 音源
//             u32 pingId, i64 t1（接收端本地微秒）
//   PONG      音源 → 接收端，收到 PING 后立即回复
//             u32 pingId, i64 t1（原样带回）, i64 t2（音源收到时刻）, i64 t3（音源发出时刻）
//   AUDIO     音源 → 各订阅者
//             u32 seq（每包加 1）, i64 playTimeUs（该包第 0 帧应当发声的音源时刻）,
//             u32 sampleRate, u8 channels, u8 sampleFormat（1 = s16 交错）, u16 frames, 然后 PCM
//             原型固定 48000 Hz、2 声道、s16、每包 240 帧（5 ms，960 字节 PCM）
//   BYE       任一方 → 对方，无负载：接收端退订 / 音源停止
//   SET_LATENCY 仅接受来自 127.0.0.1：本机 App → 音源进程
//             i32 latencyUs（目标延迟，playTimeUs = 采集时刻 + latencyUs）
#pragma once

#include <cstdint>

namespace unison {

constexpr uint32_t kMagic = 0x4E534E55;
constexpr uint8_t kVersion = 1;
constexpr int kHeaderSize = 8;

constexpr uint16_t kSourcePort = 47800;
constexpr uint16_t kBeaconPort = 47801;

enum class MsgType : uint8_t {
  Beacon = 1,
  Subscribe = 2,
  Ping = 3,
  Pong = 4,
  Audio = 5,
  Bye = 6,
  SetLatency = 7,
};

constexpr uint8_t kSampleFormatS16 = 1;
constexpr uint32_t kSampleRate = 48000;
constexpr uint8_t kChannels = 2;
constexpr uint16_t kFramesPerPacket = 240;

// AUDIO 负载中 PCM 之前的字段长度：seq 4 + playTimeUs 8 + sampleRate 4 + channels 1 + format 1 + frames 2
constexpr int kAudioFieldsSize = 20;

constexpr int64_t kSubscribeTimeoutUs = 5'000'000;
constexpr int32_t kDefaultLatencyUs = 50'000;

}  // namespace unison
