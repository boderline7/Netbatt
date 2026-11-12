#!/system/bin/sh
MODDIR=${0%/*}
BB=/data/adb/magisk/busybox
[ -x "$BB" ] || BB=/system/bin/busybox

# 先停网页，再杀守护，顺序反了守护会把网页又拉起来
pkill -f "httpd -f -p 8080" 2>/dev/null
pkill -f "netbatt/bin/nb-daemon.sh" 2>/dev/null
pkill -f "netbatt/bin/loop.sh" 2>/dev/null
pkill -f "netbatt/bin/netbatt.sh" 2>/dev/null

rm -f /data/adb/netbatt/httpd.pid /data/adb/netbatt/daemon.pid 2>/dev/null
