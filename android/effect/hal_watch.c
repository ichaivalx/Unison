// init.svc serial 记录两次采样之间的短暂 running/restarting，不能只依赖 pidof。
#include <android/binder_ibinder.h>
#include <android/binder_manager.h>
#include <sys/system_properties.h>
#include <dirent.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

struct snapshot { uint32_t serial; char value[PROP_VALUE_MAX]; };
static void property_callback(void* cookie, const char* name, const char* value, uint32_t serial) {
    (void)name;
    struct snapshot* s = cookie;
    s->serial = serial;
    snprintf(s->value, sizeof(s->value), "%s", value);
}
static struct snapshot read_property(const char* name) {
    struct snapshot result = {0};
    const prop_info* info = __system_property_find(name);
    if (info) __system_property_read_callback(info, property_callback, &result);
    return result;
}
static int is_hal(pid_t pid) {
    char path[64], name[512];
    snprintf(path, sizeof(path), "/proc/%d/cmdline", pid);
    FILE* file = fopen(path, "re");
    if (!file) return 0;
    size_t n = fread(name, 1, sizeof(name) - 1, file);
    fclose(file);
    if (!n) return 0;
    name[n] = 0;
    const char* base = strrchr(name, '/');
    return strcmp(base ? base + 1 : name, "audiohalservice.qti") == 0;
}
static pid_t find_pid(pid_t cached) {
    if (cached > 0 && is_hal(cached)) return cached;
    DIR* dir = opendir("/proc");
    if (!dir) return 0;
    struct dirent* entry;
    pid_t found = 0;
    while ((entry = readdir(dir))) {
        char* end;
        long value = strtol(entry->d_name, &end, 10);
        if (*end || value <= 0) continue;
        if (is_hal((pid_t)value)) { found = (pid_t)value; break; }
    }
    closedir(dir);
    return found;
}
int main(int argc, char** argv) {
    if (argc == 2 && strcmp(argv[1], "--check-factory") == 0) {
        AIBinder* binder = AServiceManager_checkService("android.hardware.audio.effect.IFactory/default");
        if (!binder) return 1;
        int healthy = AIBinder_isAlive(binder) && AIBinder_ping(binder) == STATUS_OK;
        AIBinder_decStrong(binder);
        return healthy ? 0 : 1;
    }
    if (argc != 3 || strcmp(argv[1], "--watch") != 0) return 2;
    char property[PROP_NAME_MAX + 256];
    if (snprintf(property, sizeof(property), "init.svc.%s", argv[2]) >= (int)sizeof(property)) return 2;
    struct snapshot previous = {0};
    uint32_t restarts = 0;
    pid_t last_pid = 0;
    for (;;) {
        struct snapshot state = read_property(property);
        int running = strcmp(state.value, "running") == 0;
        int restarting = strcmp(state.value, "restarting") == 0;
        int was_running = strcmp(previous.value, "running") == 0;
        int was_restarting = strcmp(previous.value, "restarting") == 0;
        // Bionic 每次更新将低 24 位 serial 加 2；两次状态变化意味着完整的一次重启，
        // 即使快照两端均为 restarting，也不会漏掉中间仅存活几十毫秒的进程。
        uint32_t updates = ((state.serial - previous.serial) & 0xffffffu) / 2;
        if ((running || restarting) && (was_running || was_restarting)) {
            restarts += updates / 2;
            if (was_running && restarting && (updates & 1)) ++restarts;
        } else if (restarting && !was_restarting) {
            ++restarts;
        }
        previous = state;
        last_pid = running ? find_pid(last_pid) : 0;
        struct snapshot boot = read_property("sys.boot_completed");
        struct timespec now;
        clock_gettime(CLOCK_BOOTTIME, &now);
        printf("%lld %s %d %u %s\n", (long long)now.tv_sec,
            state.value[0] ? state.value : "unknown", last_pid, restarts, boot.value[0] ? boot.value : "0");
        if (fflush(stdout) != 0) return 0;
        struct timespec interval = {.tv_sec = 0, .tv_nsec = 100000000};
        while (nanosleep(&interval, &interval) != 0 && errno == EINTR) {}
    }
}
