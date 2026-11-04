#!/system/bin/sh
ORIGINAL=/odm/etc/audio_effects_config.xml
SOUNDFX=/odm/lib64/soundfx
RUNTIME="$MODDIR/runtime"

init_mount_namespace() {
  local current initial
  current=$(readlink /proc/self/ns/mnt) || return 1
  initial=$(readlink /proc/1/ns/mnt) || return 1
  if [ "$current" != "$initial" ]; then
    exec /data/adb/ksu/bin/busybox nsenter -t 1 -m /data/adb/ksu/bin/busybox sh "$0"
  fi
}

same_inode() {
  local identity
  [ -e "$1" ] && [ -e "$2" ] || return 1
  identity=$(stat -Lc '%d:%i' "$1") || return 1
  [ "$identity" = "$(stat -Lc '%d:%i' "$2")" ]
}

load_mount_state() {
  ACTIVE_CONFIG=
  ACTIVE_LIBS=
  [ -f "$RUNTIME/mount-state" ] || return 0
  { IFS= read -r ACTIVE_CONFIG; IFS= read -r ACTIVE_LIBS; } < "$RUNTIME/mount-state"
}

module_mounted() {
  same_inode "$ACTIVE_CONFIG" "$ORIGINAL" || same_inode "$ACTIVE_LIBS" "$SOUNDFX"
}

unmount_module() {
  local result=0
  # 只撤销仍指向本模块源 inode 的挂载，不碰其他模块后来覆盖的挂载。
  if same_inode "$ACTIVE_CONFIG" "$ORIGINAL"; then umount -l "$ORIGINAL" || result=1; fi
  if same_inode "$ACTIVE_LIBS" "$SOUNDFX"; then umount -l "$SOUNDFX" || result=1; fi
  return "$result"
}

stage_mounted() {
  local stage_name=${1##*/}
  awk -v part="/runtime/$stage_name" '
    index($4, part) && (substr($4, index($4, part) + length(part), 1) == "/" ||
                       length($4) == index($4, part) + length(part) - 1) { found=1 }
    END { exit !found }
  ' /proc/self/mountinfo
}

cleanup_stages() {
  local old
  for old in "$RUNTIME"/boot.*; do
    [ -d "$old" ] || continue
    stage_mounted "$old" || rm -rf "$old"
  done
}
