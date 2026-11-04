#include "unison/receiver.h"
#include "unison/protocol.h"
#include <array>
#include <algorithm>
#include <iostream>
#include <stdexcept>
#include <thread>
#include <chrono>
#ifdef _WIN32
#include <winsock2.h>
#else
#include <arpa/inet.h>
#include <sys/socket.h>
#include <sys/select.h>
#include <unistd.h>
#endif
int main() {
#ifdef _WIN32
    WSADATA data{}; if (WSAStartup(MAKEWORD(2, 2), &data)) return 5;
#endif
    unison::Receiver receiver;
    const uint64_t id = receiver.receiverId();
    if (!receiver.start("127.0.0.1")) return 1;
    auto socketFd = socket(AF_INET, SOCK_DGRAM, 0);
    sockaddr_in address{}; address.sin_family = AF_INET; address.sin_port = htons(unison::kSourcePort); address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(socketFd, reinterpret_cast<sockaddr*>(&address), sizeof(address))) return 2;
    sockaddr_in peer{};
    auto subscribedId = [&]() -> uint64_t {
        const auto deadline = unison::monotonicUs() + 3'000'000;
        while (unison::monotonicUs() < deadline) {
            fd_set readable; FD_ZERO(&readable); FD_SET(socketFd, &readable); timeval wait{0, 100000};
            if (select(static_cast<int>(socketFd + 1), &readable, nullptr, nullptr, &wait) <= 0) continue;
            std::array<unsigned char, 2048> bytes{};
            #ifdef _WIN32
            int peerSize = sizeof(peer);
#else
            socklen_t peerSize = sizeof(peer);
#endif
            int n = static_cast<int>(recvfrom(socketFd, reinterpret_cast<char*>(bytes.data()), static_cast<int>(bytes.size()), 0,
                reinterpret_cast<sockaddr*>(&peer), &peerSize));
            if (n >= 18 && bytes[5] == static_cast<unsigned char>(unison::MsgType::Subscribe)) {
                uint64_t value = 0; for (int i = 0; i < 8; ++i) value |= uint64_t(bytes[8 + i]) << (8 * i); return value;
            }
        }
        throw std::runtime_error("SUBSCRIBE timeout");
    };
    if (subscribedId() != id) return 3;
    receiver.stop();
    if (receiver.receiverId() != id || !receiver.start("127.0.0.1") || subscribedId() != id) return 4;
    auto put = [](unsigned char* out, uint64_t value, int n) { for (int i = 0; i < n; ++i) out[i] = static_cast<unsigned char>(value >> (8 * i)); };
    auto send = [&](const auto& bytes) { sendto(socketFd, reinterpret_cast<const char*>(bytes.data()), static_cast<int>(bytes.size()), 0,
        reinterpret_cast<sockaddr*>(&peer), sizeof(peer)); };
    // 使用真实 PING/PONG 建立时钟，再制造一个序号缺口及随后的音源静默。
    std::array<unsigned char, 2048> ping{};
#ifdef _WIN32
    int peerSize = sizeof(peer);
#else
    socklen_t peerSize = sizeof(peer);
#endif
    auto synchronizeClock = [&]() {
      const auto receiverAddress = peer;
      const auto clockDeadline = unison::monotonicUs() + 3'000'000;
      while (receiver.statsJson().find("\"clockReady\":true") == std::string::npos) {
        if (unison::monotonicUs() > clockDeadline) throw std::runtime_error("Clock timeout");
        fd_set readable; FD_ZERO(&readable); FD_SET(socketFd, &readable); timeval wait{0, 100000};
        if (select(static_cast<int>(socketFd + 1), &readable, nullptr, nullptr, &wait) <= 0) continue;
        int n = static_cast<int>(recvfrom(socketFd, reinterpret_cast<char*>(ping.data()), static_cast<int>(ping.size()), 0,
            reinterpret_cast<sockaddr*>(&peer), &peerSize));
        if (n < 20 || ping[5] != 3 || peer.sin_port != receiverAddress.sin_port) continue;
        std::array<unsigned char, 36> pong{}; put(pong.data(), unison::kMagic, 4); pong[4] = 1; pong[5] = 4;
        std::copy(ping.begin() + 8, ping.begin() + 20, pong.begin() + 8);
        put(pong.data() + 20, unison::monotonicUs(), 8); put(pong.data() + 28, unison::monotonicUs(), 8); send(pong);
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
      }
      peer = receiverAddress;
    };
    synchronizeClock();
    std::this_thread::sleep_for(std::chrono::milliseconds(20));
    const int64_t play = unison::monotonicUs() + 1'000'000;
    std::array<unsigned char, 988> audio{}; put(audio.data(), unison::kMagic, 4); audio[4] = 1; audio[5] = 5;
    put(audio.data() + 20, 48000, 4); audio[24] = 2; audio[25] = 1; put(audio.data() + 26, 240, 2);
    put(audio.data() + 8, 100, 4); put(audio.data() + 12, play, 8); send(audio);
    put(audio.data() + 8, 102, 4); put(audio.data() + 12, play + 10000, 8); send(audio);
    std::this_thread::sleep_for(std::chrono::milliseconds(20));
    std::array<float, 480> output{};
    for (int i = 0; i < 220; ++i) receiver.render(output.data(), 240, 48000, play + i * 5000LL, true);
    if (receiver.statsJson().find("\"lostPackets\":1,") == std::string::npos) { std::cerr << receiver.statsJson(); return 6; }
    receiver.stop();
    // 新连接从未启动输出，之后模拟输出开始又中断；真实时间推进时队列必须受播放期限约束。
    for (;;) {
        fd_set readable; FD_ZERO(&readable); FD_SET(socketFd, &readable); timeval wait{0, 0};
        if (select(static_cast<int>(socketFd + 1), &readable, nullptr, nullptr, &wait) <= 0) break;
        recvfrom(socketFd, reinterpret_cast<char*>(ping.data()), static_cast<int>(ping.size()), 0, nullptr, nullptr);
    }
    if (!receiver.start("127.0.0.1") || subscribedId() != id) return 8;
    synchronizeClock();
    receiver.setOffsetUs(25000);
    auto queued = [&]() {
        const auto text = receiver.statsJson();
        const auto at = text.find("\"queuedPackets\":") + 16;
        return std::stoul(text.substr(at));
    };
    size_t largest = 0;
    for (int phase = 0; phase < 2; ++phase) {
        if (phase) receiver.render(output.data(), 240, 48000, unison::monotonicUs() + 20000, true);
        for (int i = 0; i < 200; ++i) {
            put(audio.data() + 8, 2000 + phase * 200 + i, 4);
            put(audio.data() + 12, unison::monotonicUs() + 200000, 8); send(audio);
            largest = std::max(largest, static_cast<size_t>(queued()));
            std::this_thread::sleep_for(std::chrono::milliseconds(5));
        }
    }
    if (largest > 80) { std::cerr << "Unbounded queue: " << receiver.statsJson(); return 9; }
    std::this_thread::sleep_for(std::chrono::milliseconds(350));
    if (queued() != 0) { std::cerr << "Expired audio remains: " << receiver.statsJson(); return 10; }
    receiver.stop();
#ifdef _WIN32
    closesocket(socketFd);
    WSACleanup();
#else
    close(socketFd);
#endif
    std::cout << "receiverId matches SUBSCRIBE; no-output queue peak=" << largest << ", expired queue=0\n";
}
