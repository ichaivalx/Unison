#!/system/bin/sh
[ "$ARCH" = arm64 ] || abort "Unison Tap 需要 arm64"
[ -f /odm/etc/audio_effects_config.xml ] || abort "缺少 /odm/etc/audio_effects_config.xml"
set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/post-fs-data.sh" 0 0 0755
ui_print "Unison Tap: 重启后加载；异常时在 KernelSU 禁用本模块并重启。"
