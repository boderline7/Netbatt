#!/system/bin/sh
MODDIR=${0%/*}
# 特权应用与权限白名单的属主/权限，必须在 early mount 之后、zygote 之前就位
PRIV="$MODDIR/system/priv-app/NetBattConsole"
mkdir -p "$PRIV"
chown -R root:root "$MODDIR/system" 2>/dev/null
chmod 755 "$MODDIR/system" "$MODDIR/system/priv-app" "$PRIV" 2>/dev/null
chmod 644 "$PRIV"/*.apk 2>/dev/null
chmod 644 "$MODDIR/system/etc/permissions/"*.xml 2>/dev/null
mkdir -p /data/adb/netbatt
