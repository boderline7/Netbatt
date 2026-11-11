#!/system/bin/sh
MODDIR=${0%/*}
sh "$MODDIR/bin/netbatt.sh" stop
pkill -f "dnsmasq.*/data/adb/netbatt" 2>/dev/null
iptables -t nat -D POSTROUTING -j NETBATT_BRIDGE 2>/dev/null
iptables -t nat -F NETBATT_BRIDGE 2>/dev/null
iptables -t nat -X NETBATT_BRIDGE 2>/dev/null
rm -f /data/adb/netbatt/httpd.pid /data/adb/netbatt/dnsmasq.pid
