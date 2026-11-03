#include "unison/receiver.h"
#include "unison/protocol.h"

#ifdef _WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#else
#include <arpa/inet.h>
#include <fcntl.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>
#endif

#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <cstring>
#include <deque>
#include <iomanip>
#include <map>
#include <mutex>
#include <sstream>
#include <thread>
#include <vector>

namespace unison {

int64_t monotonicUs() {
#ifdef _WIN32
    static const int64_t frequency = [] { LARGE_INTEGER f; QueryPerformanceFrequency(&f); return f.QuadPart; }();
    LARGE_INTEGER now;
    QueryPerformanceCounter(&now);
    return static_cast<int64_t>(static_cast<double>(now.QuadPart) * 1e6 / frequency);
#else
    timespec ts{};
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * int64_t{1'000'000} + ts.tv_nsec / 1000;
#endif
}

namespace {
#ifdef _WIN32
using Socket = SOCKET;
constexpr Socket kInvalidSocket = INVALID_SOCKET;
void closeSocket(Socket s) { if (s != kInvalidSocket) closesocket(s); }
#else
using Socket = int;
constexpr Socket kInvalidSocket = -1;
void closeSocket(Socket s) { if (s != kInvalidSocket) close(s); }
#endif
constexpr double kFrameUs = 1e6 / kSampleRate;
constexpr int64_t kPacketUs = int64_t{kFramesPerPacket} * 1'000'000 / kSampleRate;

Socket udpSocket(uint16_t port) {
    Socket s = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (s == kInvalidSocket) return s;
    int yes = 1;
    setsockopt(s, SOL_SOCKET, SO_REUSEADDR, reinterpret_cast<const char*>(&yes), sizeof(yes));
    sockaddr_in address{};
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_ANY);
    address.sin_port = htons(port);
    if (bind(s, reinterpret_cast<sockaddr*>(&address), sizeof(address)) != 0) {
        closeSocket(s);
        return kInvalidSocket;
    }
#ifdef _WIN32
    u_long nonblocking = 1;
    ioctlsocket(s, FIONBIO, &nonblocking);
#else
    fcntl(s, F_SETFL, fcntl(s, F_GETFL, 0) | O_NONBLOCK);
#endif
    return s;
}

uint64_t readLe(const uint8_t* p, int bytes) {
    uint64_t value = 0;
    for (int i = 0; i < bytes; ++i) value |= uint64_t{p[i]} << (i * 8);
    return value;
}
void writeLe(std::vector<uint8_t>& out, uint64_t value, int bytes) {
    for (int i = 0; i < bytes; ++i) out.push_back(static_cast<uint8_t>(value >> (8 * i)));
}
std::vector<uint8_t> message(MsgType type) {
    std::vector<uint8_t> out;
    writeLe(out, kMagic, 4);
    out.push_back(kVersion);
    out.push_back(static_cast<uint8_t>(type));
    writeLe(out, 0, 2);
    return out;
}
void sendMessage(Socket s, const sockaddr_in& address, const std::vector<uint8_t>& data) {
    sendto(s, reinterpret_cast<const char*>(data.data()), static_cast<int>(data.size()), 0,
           reinterpret_cast<const sockaddr*>(&address), sizeof(address));
}
bool sameAddress(const sockaddr_in& a, const sockaddr_in& b) {
    return a.sin_addr.s_addr == b.sin_addr.s_addr && a.sin_port == b.sin_port;
}
}  // namespace

struct Receiver::State {
    struct Packet {
        uint32_t seq;
        std::array<float, kFramesPerPacket * kChannels> pcm;
    };
    struct ClockSample { double rtt; double offset; };
    using PacketMap = std::map<std::pair<int64_t, uint32_t>, Packet>;
    struct Statistics {
        bool running, selected, clockReady, realTimestamp;
        in_addr sourceIp;
        double clockOffset, minRtt, bufferMs, errorUs, correction, userOffsetUs;
        uint64_t lost, late, relocations, xruns;
    };

    std::mutex mutex;
    std::atomic<bool> running{false};
    std::atomic<uint64_t> xruns{0};
    std::thread worker;
    Socket dataSocket = kInvalidSocket;
    Socket beaconSocket = kInvalidSocket;
    sockaddr_in source{};
    bool selected = false;
    bool fixedSource = false;
    bool clockReady = false;
    std::deque<ClockSample> clockSamples;
    std::map<uint32_t, int64_t> pings;
    PacketMap packets;
    uint64_t receiverId = 0;
    uint32_t pingId = 0;
    int64_t selectedAt = 0;
    int64_t lastSeen = 0;
    int64_t lastSubscribe = 0;
    int64_t lastPing = 0;
    double clockOffset = 0;
    double minRtt = 0;
    double userOffsetUs = 0;
    double readTime = 0;
    bool reading = false;
    bool haveAudio = false;
    int64_t firstAudioTime = 0;
    double lossBaseTime = 0;
    uint32_t lossBaseSeq = 0, accountedSeq = 0;
    bool accounted = false;
    double errorUs = 0;
    double integral = 0;
    double correction = 0;
    double bufferMs = 0;
    uint64_t lost = 0;
    uint64_t late = 0;
    uint64_t relocations = 0;
    bool realTimestamp = false;
#ifdef _WIN32
    bool winsock = false;
#endif

    void resetStream() {
        PacketMap retired;
        {
            std::lock_guard<std::mutex> lock(mutex);
            packets.swap(retired);
            clockReady = false;
            reading = haveAudio = false;
            clockOffset = minRtt = errorUs = integral = correction = bufferMs = 0;
            accounted = false;
        }
        clockSamples.clear();
        pings.clear();
    }

    void reclaimPackets() {
        PacketMap retired;
        {
            std::lock_guard<std::mutex> lock(mutex);
            if (!reading) return;
            // 锁内只摘取节点，锁外释放；回调只读包，不负责回收。
            while (packets.size() > 1 && std::next(packets.begin())->first.first < readTime - kFrameUs)
                retired.insert(packets.extract(packets.begin()));
        }
    }

    Statistics snapshot() {
        std::lock_guard<std::mutex> lock(mutex);
        return {running.load(), selected, clockReady, realTimestamp, source.sin_addr,
                clockOffset, minRtt, bufferMs, errorUs, correction, userOffsetUs,
                lost, late, relocations, xruns.load()};
    }

    void selectSource(const sockaddr_in& address, int64_t now) {
        resetStream();
        std::lock_guard<std::mutex> lock(mutex);
        source = address;
        selected = true;
        selectedAt = lastSeen = now;
        lastSubscribe = lastPing = 0;
    }

    void receive(const uint8_t* data, int size, const sockaddr_in& from, bool beacon, int64_t now) {
        if (size < kHeaderSize || readLe(data, 4) != kMagic || data[4] != kVersion) return;
        auto type = static_cast<MsgType>(data[5]);
        const uint8_t* p = data + kHeaderSize;
        int bytes = size - kHeaderSize;
        if (beacon) {
            if (type != MsgType::Beacon || bytes < 4 || bytes != 4 + readLe(p + 2, 2)) return;
            sockaddr_in advertised = from;
            advertised.sin_port = htons(static_cast<uint16_t>(readLe(p, 2)));
            if (!selected && !fixedSource) selectSource(advertised, now);
            return;
        }
        if (!selected || !sameAddress(source, from)) return;
        if (type == MsgType::Pong && bytes == 28) {
            uint32_t id = static_cast<uint32_t>(readLe(p, 4));
            int64_t t1 = static_cast<int64_t>(readLe(p + 4, 8));
            int64_t t2 = static_cast<int64_t>(readLe(p + 12, 8));
            int64_t t3 = static_cast<int64_t>(readLe(p + 20, 8));
            auto pending = pings.find(id);
            if (pending == pings.end() || pending->second != t1) return;
            pings.erase(pending);
            double rtt = static_cast<double>((now - t1) - (t3 - t2));
            if (rtt < 0 || t3 < t2) return;
            lastSeen = now;
            clockSamples.push_back({rtt, ((t2 - t1) + (t3 - now)) * 0.5});
            if (clockSamples.size() > 40) clockSamples.pop_front();
            std::vector<ClockSample> sorted(clockSamples.begin(), clockSamples.end());
            std::sort(sorted.begin(), sorted.end(), [](auto a, auto b) { return a.rtt < b.rtt; });
            size_t count = std::max<size_t>(1, sorted.size() / 4);
            double mean = 0;
            for (size_t i = 0; i < count; ++i) mean += sorted[i].offset;
            mean /= count;
            std::lock_guard<std::mutex> lock(mutex);
            minRtt = sorted.front().rtt;
            clockOffset = clockReady ? clockOffset + 0.12 * (mean - clockOffset) : mean;
            clockReady = true;
        } else if (type == MsgType::Audio) {
            if (bytes != kAudioFieldsSize + kFramesPerPacket * kChannels * 2 ||
                readLe(p + 12, 4) != kSampleRate || p[16] != kChannels ||
                p[17] != kSampleFormatS16 || readLe(p + 18, 2) != kFramesPerPacket) return;
            uint32_t seq = static_cast<uint32_t>(readLe(p, 4));
            int64_t playTime = static_cast<int64_t>(readLe(p + 4, 8));
            lastSeen = now;
            auto key = std::make_pair(playTime, seq);
            Packet packet{};
            packet.seq = seq;
            for (size_t i = 0; i < packet.pcm.size(); ++i) {
                auto value = static_cast<int16_t>(readLe(p + kAudioFieldsSize + 2 * i, 2));
                packet.pcm[i] = static_cast<float>(value) / 32768.0f;
            }
            // 提前分配 map 节点，转移到共享缓冲时不再分配内存。
            PacketMap prepared;
            prepared.emplace(key, std::move(packet));
            auto node = prepared.extract(prepared.begin());
            {
                std::lock_guard<std::mutex> lock(mutex);
                if (reading && playTime + kPacketUs <= readTime) {
                    ++late;
                } else if (packets.find(key) == packets.end()) {
                    packets.insert(std::move(node));
                    if (!haveAudio) {
                        firstAudioTime = playTime;
                        lossBaseTime = playTime;
                        lossBaseSeq = seq;
                        haveAudio = true;
                    }
                }
            }
        } else if (type == MsgType::Bye && bytes == 0) {
            if (fixedSource) selectSource(source, now);
            else {
                resetStream();
                std::lock_guard<std::mutex> lock(mutex);
                selected = false;
            }
        }
    }

    void networkLoop() {
        std::array<uint8_t, 65536> buffer{};
        while (running.load()) {
            fd_set readable;
            FD_ZERO(&readable);
            FD_SET(dataSocket, &readable);
            FD_SET(beaconSocket, &readable);
            timeval wait{0, 20'000};
            int result = select(static_cast<int>(std::max(dataSocket, beaconSocket) + 1), &readable,
                                nullptr, nullptr, &wait);
            if (result > 0) {
                for (Socket s : {beaconSocket, dataSocket}) {
                    if (!FD_ISSET(s, &readable)) continue;
                    // 一次读完已到达的数据，避免排队带来额外延迟。
                    for (;;) {
                        sockaddr_in from{};
#ifdef _WIN32
                        int fromSize = sizeof(from);
#else
                        socklen_t fromSize = sizeof(from);
#endif
                        int bytes = static_cast<int>(recvfrom(s, reinterpret_cast<char*>(buffer.data()),
                            static_cast<int>(buffer.size()), 0, reinterpret_cast<sockaddr*>(&from), &fromSize));
                        if (bytes < 0) break;
                        int64_t now = monotonicUs();
                        receive(buffer.data(), bytes, from, s == beaconSocket, now);
                    }
                }
            }
            reclaimPackets();
            int64_t now = monotonicUs();
            if (selected && now - lastSeen > kSubscribeTimeoutUs) {
                if (fixedSource) selectSource(source, now);
                else {
                    resetStream();
                    std::lock_guard<std::mutex> lock(mutex);
                    selected = false;
                }
            }
            if (!selected) continue;
            if (now - lastSubscribe >= 1'000'000) {
                auto out = message(MsgType::Subscribe);
                writeLe(out, receiverId, 8);
#ifdef _WIN32
                std::string name = "Unison Windows";
#else
                std::string name = "Unison Android";
#endif
                writeLe(out, name.size(), 2);
                out.insert(out.end(), name.begin(), name.end());
                sendMessage(dataSocket, source, out);
                lastSubscribe = now;
            }
            int64_t interval = now - selectedAt < 2'000'000 ? 100'000 : 500'000;
            if (now - lastPing >= interval) {
                auto out = message(MsgType::Ping);
                writeLe(out, ++pingId, 4);
                writeLe(out, static_cast<uint64_t>(now), 8);
                pings[pingId] = now;
                sendMessage(dataSocket, source, out);
                lastPing = now;
            }
            for (auto it = pings.begin(); it != pings.end();) {
                if (now - it->second > kSubscribeTimeoutUs) it = pings.erase(it);
                else ++it;
            }
        }
        if (selected) sendMessage(dataSocket, source, message(MsgType::Bye));
    }

    // 以包时间轴取样；缺失部分自然变为静音，不等待重传。
    void sample(double time, float& left, float& right) {
        auto it = packets.upper_bound({static_cast<int64_t>(std::floor(time)), UINT32_MAX});
        if (it != packets.begin()) {
            --it;
            auto next = std::next(it);
            bool continuous = next != packets.end() && next->second.seq == it->second.seq + 1 &&
                              next->first.first > it->first.first;
            // 按相邻 seq 的时标连接，吸收采集时钟校准引起的包边界变化。
            double packetDuration = continuous ? static_cast<double>(next->first.first - it->first.first) : kPacketUs;
            double position = (time - it->first.first) * kFramesPerPacket / packetDuration;
            int frame = static_cast<int>(std::floor(position + 1e-5));
            if (frame >= 0 && frame < kFramesPerPacket) {
                double fraction = std::clamp(position - frame, 0.0, 1.0);
                float nextLeft = it->second.pcm[frame * 2];
                float nextRight = it->second.pcm[frame * 2 + 1];
                if (frame + 1 < kFramesPerPacket) {
                    nextLeft = it->second.pcm[(frame + 1) * 2];
                    nextRight = it->second.pcm[(frame + 1) * 2 + 1];
                } else {
                    if (continuous) {
                        nextLeft = next->second.pcm[0];
                        nextRight = next->second.pcm[1];
                    }
                }
                left = static_cast<float>(it->second.pcm[frame * 2] * (1 - fraction) + nextLeft * fraction);
                right = static_cast<float>(it->second.pcm[frame * 2 + 1] * (1 - fraction) + nextRight * fraction);
                if (!accounted || it->first.first > lossBaseTime ||
                    static_cast<int32_t>(it->second.seq - accountedSeq) > 0) {
                    accounted = true;
                    accountedSeq = lossBaseSeq = it->second.seq;
                    lossBaseTime = it->first.first;
                }
                return;
            }
        }
        left = right = 0;
        if (time >= firstAudioTime) {
            int64_t slot = static_cast<int64_t>(std::floor((time - lossBaseTime) / kPacketUs));
            if (slot >= 1) {
                uint32_t missingSeq = lossBaseSeq + static_cast<uint32_t>(slot);
                if (!accounted) { accounted = true; accountedSeq = missingSeq - 1; }
                int32_t gap = static_cast<int32_t>(missingSeq - accountedSeq);
                if (gap > 0) {
                    lost += static_cast<uint32_t>(gap);
                    accountedSeq = missingSeq;
                }
            }
        }
    }
};

Receiver::Receiver() : state_(std::make_unique<State>()) {}
Receiver::~Receiver() { stop(); }

bool Receiver::start(const std::string& sourceIp) {
    auto& s = *state_;
    if (s.running.load()) return true;
#ifdef _WIN32
    WSADATA data{};
    if (WSAStartup(MAKEWORD(2, 2), &data) != 0) return false;
    s.winsock = true;
#endif
    s.dataSocket = udpSocket(0);
    s.beaconSocket = udpSocket(kBeaconPort);
    if (s.dataSocket == kInvalidSocket || s.beaconSocket == kInvalidSocket) {
        stop();
        return false;
    }
    s.resetStream();
    s.fixedSource = !sourceIp.empty();
    s.receiverId = static_cast<uint64_t>(monotonicUs());
    s.xruns.store(0);
    {
        std::lock_guard<std::mutex> lock(s.mutex);
        s.selected = false;
        s.lost = s.late = s.relocations = 0;
        s.realTimestamp = false;
    }
    if (s.fixedSource) {
        sockaddr_in address{};
        address.sin_family = AF_INET;
        address.sin_port = htons(kSourcePort);
        if (inet_pton(AF_INET, sourceIp.c_str(), &address.sin_addr) != 1) {
            stop();
            return false;
        }
        s.selectSource(address, monotonicUs());
    }
    s.running.store(true);
    s.worker = std::thread([&s] { s.networkLoop(); });
    return true;
}

void Receiver::stop() {
    auto& s = *state_;
    s.running.store(false);
    if (s.worker.joinable()) s.worker.join();
    closeSocket(s.dataSocket);
    closeSocket(s.beaconSocket);
    s.dataSocket = s.beaconSocket = kInvalidSocket;
#ifdef _WIN32
    if (s.winsock) WSACleanup();
    s.winsock = false;
#endif
    s.resetStream();
    std::lock_guard<std::mutex> lock(s.mutex);
    s.selected = false;
}

void Receiver::setOffsetMs(float ms) {
    std::lock_guard<std::mutex> lock(state_->mutex);
    state_->userOffsetUs = ms * 1000.0;
}

void Receiver::resetOutputTiming() {
    auto& s = *state_;
    std::lock_guard<std::mutex> lock(s.mutex);
    if (s.reading) ++s.relocations;
    s.reading = false;
    s.errorUs = s.integral = s.correction = 0;
}

void Receiver::addXruns(uint32_t count) { state_->xruns.fetch_add(count); }

void Receiver::render(float* stereo, int frames, int deviceRate, int64_t firstFrameUs, bool realTimestamp) {
    auto& s = *state_;
    std::fill(stereo, stereo + frames * 2, 0.0f);
    std::lock_guard<std::mutex> lock(s.mutex);
    s.realTimestamp = realTimestamp;
    if (!s.running.load() || !s.clockReady || !s.haveAudio) return;
    double desired = firstFrameUs + s.clockOffset - s.userOffsetUs;
    double duration = static_cast<double>(frames) / deviceRate;
    if (!s.reading) {
        s.readTime = desired;
        s.reading = true;
        s.errorUs = s.integral = s.correction = 0;
    } else {
        double alpha = duration / (0.25 + duration);
        s.errorUs += alpha * ((desired - s.readTime) - s.errorUs);
        if (std::abs(s.errorUs) > 20'000) {
            s.readTime = desired;
            s.errorUs = s.integral = s.correction = 0;
            ++s.relocations;
        } else {
            s.integral = std::clamp(s.integral + s.errorUs * 1e-6 * duration, -0.08, 0.08);
            s.correction = std::clamp(0.18 * s.errorUs * 1e-6 + 0.025 * s.integral, -0.003, 0.003);
        }
    }
    double step = 1e6 / deviceRate * (1.0 + s.correction);
    for (int i = 0; i < frames; ++i) {
        s.sample(s.readTime, stereo[i * 2], stereo[i * 2 + 1]);
        s.readTime += step;
    }
    s.bufferMs = s.packets.empty() ? 0 : std::max(0.0, (s.packets.rbegin()->first.first + kPacketUs - s.readTime) / 1000.0);
}

std::string Receiver::statsJson() {
    auto s = state_->snapshot();
    char ip[INET_ADDRSTRLEN]{};
    if (s.selected) inet_ntop(AF_INET, &s.sourceIp, ip, sizeof(ip));
    std::ostringstream out;
    out.imbue(std::locale::classic());
    out << std::fixed << std::setprecision(3)
        << "{\"running\":" << (s.running ? "true" : "false")
        << ",\"source\":\"" << ip << "\",\"clockReady\":" << (s.clockReady ? "true" : "false")
        << ",\"clockOffsetMs\":" << s.clockOffset / 1000
        << ",\"minRttMs\":" << s.minRtt / 1000
        << ",\"bufferMs\":" << s.bufferMs
        << ",\"lostPackets\":" << s.lost << ",\"latePackets\":" << s.late
        << ",\"syncErrorMs\":" << s.errorUs / 1000
        << ",\"speedPpm\":" << s.correction * 1e6
        << ",\"relocations\":" << s.relocations
        << ",\"xruns\":" << s.xruns
        << ",\"offsetMs\":" << s.userOffsetUs / 1000
        << ",\"timestamp\":\"" << (s.realTimestamp ? "real" : "fallback") << "\"}";
    return out.str();
}

std::string Receiver::statsLine() {
    auto s = state_->snapshot();
    std::ostringstream out;
    out.imbue(std::locale::classic());
    out << std::fixed << std::setprecision(2)
        << (s.clockReady ? "sync " : "waiting ")
        << "err=" << s.errorUs / 1000 << "ms buf=" << s.bufferMs
        << " rtt=" << s.minRtt / 1000
        << " xrun=" << s.xruns
        << " lost=" << s.lost << " late=" << s.late
        << " ppm=" << std::setprecision(0) << s.correction * 1e6
        << " seek=" << s.relocations << " ts=" << (s.realTimestamp ? "real" : "fallback")
        << " offset=" << s.userOffsetUs / 1000 << "ms clk=" << std::setprecision(2) << s.clockOffset / 1000;
    return out.str();
}

}  // namespace unison
