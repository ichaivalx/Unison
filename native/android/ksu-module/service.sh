#!/system/bin/sh
MODDIR=${0%/*}
. "$MODDIR/mount-utils.sh"
init_mount_namespace || exit 0
[ -f "$MODDIR/disable" ] && exit 0
BOOT_ID=$(cat /proc/sys/kernel/random/boot_id) || exit 0
mkdir -p "$RUNTIME" || exit 0
exec 8> "$RUNTIME/service.lock"
flock -n 8 || exit 0
load_mount_state
WATCHER="$MODDIR/bin/unison_hal_watch"
RESULT="$RUNTIME/guard-result"
rm -f "$RESULT"

uptime_seconds() { local seconds rest; read -r seconds rest < /proc/uptime; printf '%s\n' "${seconds%%.*}"; }
rollback() {
  local reason=$1
  load_mount_state
  unmount_module
  if : > "$MODDIR/disable"; then rm -f "$MODDIR/boot-pending"; fi
  printf '%s\n' "$reason" > "$MODDIR/rollback-reason"
  if ! same_inode "$ACTIVE_CONFIG" "$ORIGINAL"; then
    set -- $(pidof audiohalservice.qti)
    for hal_pid in "$@"; do kill -KILL "$hal_pid"; done
  else
    printf '%s rollback_unmount_failed\n' "$reason" > "$MODDIR/rollback-reason"
  fi
  cleanup_stages
  printf 'rolled_back\n' > "$RESULT"
}

# 从实际 rc 的 service 声明提取 init 名称，进程名不等于 init 服务名。
HAL_SERVICE=$(awk '
  $1 == "service" { path=$3; sub(/^.*\//, "", path); if (path == "audiohalservice.qti") { print $2; exit } }
' /vendor/etc/init/*.rc /odm/etc/init/*.rc /vendor/etc/init/hw/*.rc 2>/dev/null)
if [ -z "$HAL_SERVICE" ] || [ ! -x "$WATCHER" ]; then
  rollback "hal_guard_unavailable service=$HAL_SERVICE"
  exit 0
fi
printf '%s\n' "$HAL_SERVICE" > "$RUNTIME/hal-service"
start=$(uptime_seconds)
deadline=$((start + 180))
boot_stable_since=0
hal_stable_since=0
last_pid=0
last_restarts=0
marker_cleared=0

# Native helper 每 100ms 快照 init 属性，并用 serial 增量补计采样间的短命重启。
"$WATCHER" --watch "$HAL_SERVICE" |
while read -r now state current_pid restarts boot_complete; do
  if [ -f "$MODDIR/disable" ]; then printf 'disabled\n' > "$RESULT"; exit 0; fi
  if [ "$state" = running ] && [ "$current_pid" -gt 0 ]; then
    if [ "$last_pid" != "$current_pid" ] || [ "$last_restarts" != "$restarts" ] || [ "$hal_stable_since" -eq 0 ]; then
      hal_stable_since=$now
    fi
  else
    hal_stable_since=0
  fi
  last_pid=$current_pid
  last_restarts=$restarts
  if [ "$restarts" -ge 3 ]; then
    rollback "audio_hal_restarted count=$restarts service=$HAL_SERVICE uptime=$now"
    exit 0
  fi
  if [ "$boot_complete" = 1 ]; then
    [ "$boot_stable_since" -eq 0 ] && boot_stable_since=$now
  else
    boot_stable_since=0
  fi
  if [ "$marker_cleared" -eq 0 ] && [ "$boot_stable_since" -gt 0 ] && [ $((now - boot_stable_since)) -ge 60 ]; then
    if [ "$state" != running ] || [ "$hal_stable_since" -eq 0 ] || [ $((now - hal_stable_since)) -lt 30 ] ||
       ! timeout 2 "$WATCHER" --check-factory; then
      rollback "hal_not_stable service=$HAL_SERVICE state=$state pid=$current_pid uptime=$now"
      exit 0
    fi
    pending_boot=
    [ -f "$MODDIR/boot-pending" ] && IFS= read -r pending_boot < "$MODDIR/boot-pending"
    if [ "$pending_boot" = "$BOOT_ID" ]; then rm -f "$MODDIR/boot-pending"; fi
    marker_cleared=1
    cleanup_stages
  fi
  if [ "$now" -ge "$deadline" ]; then
    if [ "$marker_cleared" -eq 0 ]; then
      rollback "boot_or_hal_not_ready service=$HAL_SERVICE uptime=$now"
    else
      printf 'healthy\n' > "$RESULT"
    fi
    exit 0
  fi
done
# 包括 helper 无法加载/异常退出的情形，绝不静默失去保护。
[ -f "$RESULT" ] || rollback "hal_watcher_exited service=$HAL_SERVICE"
