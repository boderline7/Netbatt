#!/system/bin/sh
MODDIR=${0%/*}
BB=/data/adb/magisk/busybox
[ -x "$BB" ] || BB=/system/bin/busybox
mkdir -p /data/adb/netbatt
until [ "$(getprop sys.boot_completed)" = 1 ]; do sleep 2; done
sleep 8
sh "$MODDIR/bin/netbatt.sh" init >/dev/null 2>&1
# adb 恢复要等 adbd 真起来，最多 40 秒，放后台别挡网页服务
$BB setsid sh -c '. /data/adb/modules/netbatt/bin/nb-lib.sh; adb_tcp_restore' >/dev/null 2>&1 &
sh "$MODDIR/bin/netbatt.sh" web
$BB setsid sh "$MODDIR/bin/loop.sh" >/dev/null 2>&1 &
