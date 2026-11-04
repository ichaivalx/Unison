#include "unison/receiver.h"
#include "unison/protocol.h"
#include <array>
#include <iostream>
#include <stdexcept>
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
    auto subscribedId = [&]() -> uint64_t {
        const auto deadline = unison::monotonicUs() + 3'000'000;
        while (unison::monotonicUs() < deadline) {
            fd_set readable; FD_ZERO(&readable); FD_SET(socketFd, &readable); timeval wait{0, 100000};
            if (select(static_cast<int>(socketFd + 1), &readable, nullptr, nullptr, &wait) <= 0) continue;
            std::array<unsigned char, 2048> bytes{};
            int n = static_cast<int>(recv(socketFd, reinterpret_cast<char*>(bytes.data()), static_cast<int>(bytes.size()), 0));
            if (n >= 18 && bytes[5] == static_cast<unsigned char>(unison::MsgType::Subscribe)) {
                uint64_t value = 0; for (int i = 0; i < 8; ++i) value |= uint64_t(bytes[8 + i]) << (8 * i); return value;
            }
        }
        throw std::runtime_error("SUBSCRIBE timeout");
    };
    if (subscribedId() != id) return 3;
    receiver.stop();
    if (receiver.receiverId() != id || !receiver.start("127.0.0.1") || subscribedId() != id) return 4;
    receiver.stop();
#ifdef _WIN32
    closesocket(socketFd);
    WSACleanup();
#else
    close(socketFd);
#endif
    std::cout << "receiverId remains stable and matches SUBSCRIBE\n";
}
