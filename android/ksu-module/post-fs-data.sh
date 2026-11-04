#!/system/bin/sh
MODDIR=${0%/*}
ORIGINAL=/odm/etc/audio_effects_config.xml
SOUNDFX=/odm/lib64/soundfx
RUNTIME="$MODDIR/runtime"
[ -f "$ORIGINAL" ] && [ -d "$SOUNDFX" ] || exit 0
[ -f "$MODDIR/lib64/soundfx/libunison_tap.so" ] || exit 0
# 所有准备成功后才挂载；保留原有 ODM 音效，不依赖 KernelSU metamodule。
mkdir -p "$RUNTIME/soundfx" || exit 0
awk '
  /^[[:space:]]*<\/libraries>[[:space:]]*$/ {
    print "        <library name=\"unison_tap\" path=\"libunison_tap.so\"/>"; libraries++
  }
  /^[[:space:]]*<\/effects>[[:space:]]*$/ {
    print "        <effect name=\"unison_tap\" library=\"unison_tap\" uuid=\"8e2581c2-3d9a-4e15-a77a-617f6f9e8202\" type=\"8e2581c2-3d9a-4e15-a77a-617f6f9e8201\"/>"; effects++
  }
  { print }
  END { if (libraries != 1 || effects != 1) exit 1 }
' "$ORIGINAL" > "$RUNTIME/audio_effects_config.xml" || exit 0
cp -af "$SOUNDFX/." "$RUNTIME/soundfx/" || exit 0
cp -f "$MODDIR/lib64/soundfx/libunison_tap.so" "$RUNTIME/soundfx/" || exit 0
chmod 0755 "$RUNTIME/soundfx" || exit 0
chmod 0644 "$RUNTIME/soundfx/libunison_tap.so" "$RUNTIME/audio_effects_config.xml" || exit 0
chcon -R u:object_r:vendor_file:s0 "$RUNTIME/soundfx" || exit 0
chcon u:object_r:vendor_configs_file:s0 "$RUNTIME/audio_effects_config.xml" || exit 0
mount --bind "$RUNTIME/soundfx" "$SOUNDFX" || exit 0
if ! mount --bind "$RUNTIME/audio_effects_config.xml" "$ORIGINAL"; then
  umount "$SOUNDFX"
fi
