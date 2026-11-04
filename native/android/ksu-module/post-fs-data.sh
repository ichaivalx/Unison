#!/system/bin/sh
MODDIR=${0%/*}
. "$MODDIR/mount-utils.sh"
init_mount_namespace || exit 0
BOOT_ID=$(cat /proc/sys/kernel/random/boot_id) || exit 0
[ -n "$BOOT_ID" ] || exit 0
mkdir -p "$RUNTIME" || exit 0
exec 9> "$RUNTIME/post-fs.lock"
flock -n 9 || exit 0
load_mount_state
cleanup_stages

if [ -f "$MODDIR/boot-pending" ]; then
  IFS= read -r previous_boot < "$MODDIR/boot-pending"
  if [ "$previous_boot" != "$BOOT_ID" ]; then
    if : > "$MODDIR/disable"; then rm -f "$MODDIR/boot-pending"; fi
    printf 'boot_incomplete previous_boot=%s current_boot=%s\n' "$previous_boot" "$BOOT_ID" > "$MODDIR/rollback-reason"
    exit 0
  fi
fi
[ -f "$MODDIR/disable" ] && exit 0
load_mount_state
# 同一次开机重复执行时绝不触碰正在挂载的配置或库目录。
module_mounted && exit 0
rm -f "$RUNTIME/mount-state"
ACTIVE_CONFIG=
ACTIVE_LIBS=
printf '%s\n' "$BOOT_ID" > "$MODDIR/boot-pending.new" || exit 0
mv -f "$MODDIR/boot-pending.new" "$MODDIR/boot-pending" || exit 0

[ -f "$ORIGINAL" ] && [ -d "$SOUNDFX" ] || exit 0
[ -f "$MODDIR/lib64/soundfx/libunison_tap.so" ] || exit 0
STAGE=$(mktemp -d "$RUNTIME/boot.XXXXXX") || exit 0
cleanup_current() {
  if ! stage_mounted "$STAGE"; then
    rm -rf "$STAGE"
    if [ "$ACTIVE_CONFIG" = "$STAGE/audio_effects_config.xml" ]; then rm -f "$RUNTIME/mount-state"; fi
  fi
}
trap cleanup_current EXIT
trap 'exit 0' HUP INT TERM
mkdir "$STAGE/soundfx" || exit 0
# 本阶段只有本地文件准备与 bind mount；不等待属性，不探测或调用音频服务。
awk '
  /^[[:space:]]*<\/libraries>[[:space:]]*$/ {
    print "        <library name=\"unison_tap\" path=\"libunison_tap.so\"/>"; libraries++
  }
  /^[[:space:]]*<\/effects>[[:space:]]*$/ {
    print "        <effect name=\"unison_tap\" library=\"unison_tap\" uuid=\"8e2581c2-3d9a-4e15-a77a-617f6f9e8202\" type=\"8e2581c2-3d9a-4e15-a77a-617f6f9e8201\"/>"; effects++
  }
  { print }
  END { if (libraries != 1 || effects != 1) exit 1 }
' "$ORIGINAL" > "$STAGE/config.tmp" || exit 0
cp -af "$SOUNDFX/." "$STAGE/soundfx/" || exit 0
cp -f "$MODDIR/lib64/soundfx/libunison_tap.so" "$STAGE/soundfx/" || exit 0
chmod 0755 "$STAGE/soundfx" || exit 0
chmod 0644 "$STAGE/soundfx/libunison_tap.so" "$STAGE/config.tmp" || exit 0
chcon -R u:object_r:vendor_file:s0 "$STAGE/soundfx" || exit 0
chcon u:object_r:vendor_configs_file:s0 "$STAGE/config.tmp" || exit 0
mv "$STAGE/config.tmp" "$STAGE/audio_effects_config.xml" || exit 0
ACTIVE_CONFIG="$STAGE/audio_effects_config.xml"
ACTIVE_LIBS="$STAGE/soundfx"
printf '%s\n%s\n' "$ACTIVE_CONFIG" "$ACTIVE_LIBS" > "$STAGE/mount-state.tmp" || exit 0
mv -f "$STAGE/mount-state.tmp" "$RUNTIME/mount-state" || exit 0
mount --bind "$ACTIVE_LIBS" "$SOUNDFX" || exit 0
if ! mount --bind "$ACTIVE_CONFIG" "$ORIGINAL"; then unmount_module; fi
