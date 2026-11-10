#!/system/bin/sh
MODDIR=${0%/*}
sh "$MODDIR/bin/netbatt.sh" stop
pkill -f "dnsmasq.*/data/adb/netbatt" 2>/dev/null
rm -f /data/adb/netbatt/httpd.pid /data/adb/netbatt/dnsmasq.pid
