#!/system/bin/sh
MODDIR=${0%/*}
BB=/data/adb/magisk/busybox
[ -x "$BB" ] || BB=/system/bin/busybox
mkdir -p /data/adb/netbatt
until [ "$(getprop sys.boot_completed)" = 1 ]; do sleep 2; done

# 模块升级后 WebView 里可能还是旧页面副本，APP 自己刷不掉（缓存命中时连请求都不发）。
# 按 versionCode 变化清一次它的缓存目录。必须放在 boot_completed 之后：
# post-fs-data 阶段 /data/data 还没解锁，rm 会静默失败。
VC=$(sed -n 's/^versionCode=//p' "$MODDIR/module.prop" 2>/dev/null | tr -d '\r\n ')
VC=${VC:-0}
MARK=/data/adb/netbatt/webcache.ver
if [ "$(cat "$MARK" 2>/dev/null)" != "$VC" ]; then
  rm -rf /data/data/com.netbatt.console/app_webview \
         /data/user_de/0/com.netbatt.console/app_webview \
         /data/data/com.netbatt.console/cache 2>/dev/null
  echo "$VC" > "$MARK"
fi

# 等系统把 USB / 电源节点都枚举完再开始判断，否则开机瞬间会被判成「断电」
sleep 8

chmod 755 "$MODDIR/bin"/*.sh 2>/dev/null

# 旧版守护进程如果还活着（从 v3 升级上来），先收掉
pkill -f "netbatt/bin/loop.sh" 2>/dev/null
pkill -f "netbatt/bin/netbatt.sh" 2>/dev/null
pkill -f "netbatt/bin/nb-daemon.sh" 2>/dev/null
sleep 1

# 无线 ADB 恢复要等 adbd 真起来，放后台别挡网页服务
# busybox 个别裁剪版本没有 setsid，退化成普通后台运行
if $BB setsid true >/dev/null 2>&1; then
  $BB setsid sh "$MODDIR/bin/nb-daemon.sh" adb-restore >/dev/null 2>&1 &
  $BB setsid sh "$MODDIR/bin/nb-daemon.sh" >/dev/null 2>&1 &
else
  sh "$MODDIR/bin/nb-daemon.sh" adb-restore >/dev/null 2>&1 &
  sh "$MODDIR/bin/nb-daemon.sh" >/dev/null 2>&1 &
fi
