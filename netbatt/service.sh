#!/system/bin/sh
MODDIR=${0%/*}
BB=/data/adb/magisk/busybox
[ -x "$BB" ] || BB=/system/bin/busybox
mkdir -p /data/adb/netbatt
until [ "$(getprop sys.boot_completed)" = 1 ]; do sleep 2; done
sleep 8
sh "$MODDIR/bin/netbatt.sh" init >/dev/null 2>&1
sh "$MODDIR/bin/netbatt.sh" web
$BB setsid sh "$MODDIR/bin/loop.sh" >/dev/null 2>&1 &
