#include <jni.h>
#include <cerrno>
#include <climits>
#include <cstddef>
#include <cstring>
#include <cstdio>
#include <poll.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include "tap_packet.h"

static void fail(JNIEnv* env, const char* operation) {
    const int saved = errno;
    char message[256];
    snprintf(message, sizeof(message), "%s: %s", operation, strerror(saved));
    env->ThrowNew(env->FindClass("java/io/IOException"), message);
}
extern "C" JNIEXPORT jint JNICALL
Java_io_github_ichaivalx_unison_capture_EffectSource_openTap(JNIEnv* env, jobject) {
    const int fd = socket(AF_UNIX, SOCK_DGRAM | SOCK_CLOEXEC, 0);
    if (fd < 0) { fail(env, "tap socket"); return -1; }
    sockaddr_un address{};
    address.sun_family = AF_UNIX;
    memcpy(address.sun_path + 1, UNISON_TAP_SOCKET, sizeof(UNISON_TAP_SOCKET) - 1);
    if (bind(fd, reinterpret_cast<sockaddr*>(&address), offsetof(sockaddr_un, sun_path) + sizeof(UNISON_TAP_SOCKET)) != 0) {
        const int saved = errno; close(fd); errno = saved; fail(env, "tap bind"); return -1;
    }
    return fd;
}
extern "C" JNIEXPORT jbyteArray JNICALL
Java_io_github_ichaivalx_unison_capture_EffectSource_readTap(JNIEnv* env, jobject, jint fd) {
    pollfd wait{fd, POLLIN, 0};
    int ready;
    do { ready = poll(&wait, 1, 5); } while (ready < 0 && errno == EINTR);
    if (ready == 0) return nullptr;
    if (ready < 0) { fail(env, "tap poll"); return nullptr; }
    const ssize_t count = recv(fd, nullptr, 0, MSG_PEEK | MSG_TRUNC | MSG_DONTWAIT);
    if (count <= 0) {
        if (count < 0 && errno != EAGAIN) fail(env, "tap peek");
        return nullptr;
    }
    if (count > INT_MAX) { errno = EMSGSIZE; fail(env, "tap packet"); return nullptr; }
    jbyteArray result = env->NewByteArray(static_cast<jsize>(count));
    if (!result) return nullptr;
    jbyte* data = env->GetByteArrayElements(result, nullptr);
    if (!data) return nullptr;
    const ssize_t received = recv(fd, data, count, MSG_DONTWAIT);
    env->ReleaseByteArrayElements(result, data, 0);
    if (received != count) { if (received >= 0) errno = EMSGSIZE; fail(env, "tap receive"); return nullptr; }
    return result;
}
extern "C" JNIEXPORT void JNICALL
Java_io_github_ichaivalx_unison_capture_EffectSource_closeTap(JNIEnv*, jobject, jint fd) {
    if (fd >= 0) { shutdown(fd, SHUT_RD); close(fd); }
}
