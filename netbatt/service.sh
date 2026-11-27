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

# 重启后内核会把 constant_charge_current 之类节点恢复成默认值（实测变 5850000、
# 也就是又开始充），而状态机按「状态没变化就不写」会一直不动，只能等 10 分钟兜底。
# 清掉 last，让守护进程第一轮就把当前意图重新下发一遍。
rm -f /data/adb/netbatt/chg.last

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

# 部分 ROM 会对新装应用套「限制后台流量」策略（netd 里是 REJECT_RESTRICTED_MODE），
# 连 127.0.0.1 都被拒 —— 表现是控制台白屏、按钮点了没反应，adb 里 ss 只能看到 SYN-SENT。
# 应用重装会换 uid，名单里的旧条目就失效了，所以每次开机补一次。
# 必须放在守护进程启动之后、并且放到后台：这条命令要跟 netd 打交道，
# 开机瞬间可能慢，绝不能挡住守护和网页服务。
(
  . "$MODDIR/bin/nb-core.sh"

  # 这台 ROM 的 netpolicy 只认数字 UID，传包名会直接报
  # "Error: UID (com.netbatt.console) should be a number"（v5.0.13 之前一直失败）。
  # 三个来源依次兜底：数据目录属主 -> pm list -U -> dumpsys。
  uid=$(stat -c %u /data/data/com.netbatt.console 2>/dev/null)
  [ -n "$uid" ] || uid=$(pm list packages -U 2>/dev/null \
      | sed -n 's/^package:com\.netbatt\.console uid:\([0-9]*\).*/\1/p' | head -1)
  [ -n "$uid" ] || uid=$(dumpsys package com.netbatt.console 2>/dev/null \
      | sed -n 's/.*userId=\([0-9]*\).*/\1/p' | head -1)

  if [ -z "$uid" ]; then
    log "网络策略: 取不到控制台 uid，跳过（控制台可能白屏）"
    exit 0
  fi

  i=0
  err=""
  while [ "$i" -lt 30 ]; do
    if err=$(cmd netpolicy add restrict-background-whitelist "$uid" 2>&1); then
      log "网络策略: 控制台 uid=$uid 已加入不受限名单"
      exit 0
    fi
    i=$((i + 1))
    sleep 2
  done
  log "网络策略: uid=$uid 加入不受限名单失败（$err），控制台可能白屏"
) >/dev/null 2>&1 &
