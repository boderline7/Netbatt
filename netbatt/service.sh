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

sleep 8
sh "$MODDIR/bin/netbatt.sh" init >/dev/null 2>&1
# adb 恢复要等 adbd 真起来，最多 40 秒，放后台别挡网页服务
$BB setsid sh -c '. /data/adb/modules/netbatt/bin/nb-lib.sh; adb_tcp_restore' >/dev/null 2>&1 &
sh "$MODDIR/bin/netbatt.sh" web
$BB setsid sh "$MODDIR/bin/loop.sh" >/dev/null 2>&1 &
