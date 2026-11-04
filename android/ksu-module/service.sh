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

uptime_seconds() { local seconds rest; read -r seconds rest < /proc/uptime; printf '%s\n' "${seconds%%.*}"; }
start=$(uptime_seconds)
deadline=$((start + 180))
stable_since=0
last_pid=
restarts=0
marker_cleared=0

while :; do
  [ -f "$MODDIR/disable" ] && exit 0
  now=$(uptime_seconds)
  if [ "$now" -lt "$deadline" ]; then
    set -- $(pidof audiohalservice.qti)
    current_pid=${1:-}
    if [ -n "$current_pid" ]; then
      if [ -n "$last_pid" ] && [ "$current_pid" != "$last_pid" ]; then restarts=$((restarts + 1)); fi
      last_pid=$current_pid
    fi
    if [ "$restarts" -ge 3 ]; then
      load_mount_state
      unmount_module
      if : > "$MODDIR/disable"; then rm -f "$MODDIR/boot-pending"; fi
      printf 'audio_hal_restarted count=%s pid=%s uptime=%s\n' "$restarts" "$current_pid" "$now" > "$MODDIR/rollback-reason"
      # 配置已恢复后，只结束一次 HAL，由 init 使用原始配置拉起；不做循环重启。
      if ! same_inode "$ACTIVE_CONFIG" "$ORIGINAL"; then
        set -- $(pidof audiohalservice.qti)
        for hal_pid in "$@"; do kill -KILL "$hal_pid"; done
      else
        printf 'audio_hal_restarted count=%s rollback_unmount_failed uptime=%s\n' "$restarts" "$now" > "$MODDIR/rollback-reason"
      fi
      exit 0
    fi
  fi
  if [ "$marker_cleared" -eq 0 ]; then
    if [ "$(getprop sys.boot_completed)" = 1 ]; then
      [ "$stable_since" -eq 0 ] && stable_since=$now
      if [ $((now - stable_since)) -ge 60 ]; then
        pending_boot=
        [ -f "$MODDIR/boot-pending" ] && IFS= read -r pending_boot < "$MODDIR/boot-pending"
        if [ "$pending_boot" = "$BOOT_ID" ]; then rm -f "$MODDIR/boot-pending"; fi
        marker_cleared=1
      fi
    else
      stable_since=0
    fi
  fi
  [ "$now" -ge "$deadline" ] && [ "$marker_cleared" -eq 1 ] && exit 0
  sleep 1
done
