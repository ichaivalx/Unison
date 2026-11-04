#include <errno.h>
#include <fcntl.h>
#include <jni.h>
#include <signal.h>
#include <unistd.h>

static int signal_pipe[2] = {-1, -1};

static void on_termination(int number) {
    const int saved_errno = errno;
    const unsigned char value = (unsigned char) number;
    // 信号处理器只写管道，由 Java 线程执行 Binder 注销。
    const ssize_t ignored = write(signal_pipe[1], &value, sizeof(value));
    (void) ignored;
    errno = saved_errno;
}

JNIEXPORT jint JNICALL
Java_io_github_ichaivalx_unison_capture_CaptureMain_installTerminationHandler(
        JNIEnv *env, jclass type) {
    (void) env;
    (void) type;
    if (pipe2(signal_pipe, O_CLOEXEC) != 0) return -errno;
    if (fcntl(signal_pipe[1], F_SETFL, O_NONBLOCK) == -1) goto failed;
    struct sigaction action = {0};
    action.sa_handler = on_termination;
    sigemptyset(&action.sa_mask);
    action.sa_flags = SA_RESTART;
    if (sigaction(SIGTERM, &action, NULL) != 0) goto failed;
    return 0;

failed: {
    const int error = errno;
    close(signal_pipe[0]);
    close(signal_pipe[1]);
    signal_pipe[0] = signal_pipe[1] = -1;
    return -error;
}
}

JNIEXPORT jint JNICALL
Java_io_github_ichaivalx_unison_capture_CaptureMain_waitForTermination(
        JNIEnv *env, jclass type) {
    (void) env;
    (void) type;
    unsigned char value = 0;
    ssize_t result;
    do {
        result = read(signal_pipe[0], &value, sizeof(value));
    } while (result == -1 && errno == EINTR);
    return result == 1 ? value : -errno;
}
