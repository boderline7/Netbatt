#!/system/bin/sh
# NetBatt 网页服务 + 状态 JSON
# 依赖 nb-core.sh / nb-facts.sh / nb-decide.sh / nb-chg.sh / nb-adb.sh。

wlan_ip() {
  for i in wlan0 wlan1; do
    ip4=$(ip -o -4 addr show dev "$i" 2>/dev/null | $BB awk '$4 !~ /^127\./ {print $4; exit}' | $BB cut -d/ -f1)
    [ -n "$ip4" ] && { echo "$ip4"; return 0; }
  done
  return 1
}

# 热点开着时用热点接口的真实 IP；否则退到 wlan0（手机连路由器时的局域网地址）。
# 都不存在就返回空，绝不编一个不存在的地址。
web_url() {
  a=$(ap_iface 2>/dev/null)
  if [ -n "$a" ]; then
    ip4=$(ip -o -4 addr show dev "$a" 2>/dev/null | $BB awk '$4 !~ /^127\./ {print $4; exit}' | $BB cut -d/ -f1)
    [ -n "$ip4" ] && { echo "http://$ip4:$PORT"; return; }
  fi
  ip4=$(wlan_ip)
  [ -n "$ip4" ] && { echo "http://$ip4:$PORT"; return; }
  echo ""
}

ap_ip() {
  a=$(ap_iface 2>/dev/null) || return 0
  ip -o -4 addr show dev "$a" 2>/dev/null | $BB awk '$4 !~ /^127\./ {print $4; exit}' | $BB cut -d/ -f1
}

status_json() {
  now=$(date '+%s')

  # 只读事实，不推进状态机，避免和守护进程抢着写
  power_read

  # 空转倒计时剩余秒数（只在 AUTO、热点开着、有计时器时有效）
  idle_left=0
  t=$($BB cat "$DATA/idle.since" 2>/dev/null)
  lim=${IDLE_OFF_MIN:-0}
  case "$lim" in ''|*[!0-9]*) lim=0 ;; esac
  if [ -n "$t" ] && [ "$lim" -gt 0 ]; then
    case "$t" in ''|*[!0-9]*) t=$now ;; esac
    left=$(( lim * 60 - (now - t) ))
    [ "$left" -gt 0 ] && idle_left=$left
  fi

  a=$(ap_iface 2>/dev/null)
  fo=$(force_get); case "$fo" in 0|1) ;; *) fo=null ;; esac
  cat <<EOF
{"build":$(nb_build),"ver":"$(nb_ver)",
"mode":"$(hs_mode)","force":$fo,"suppress":$(suppress_get),
"power":${POWER:-0},"power_raw":${POWER_RAW:-0},
"ap":$(ap_running),"ap_if":"$a","ap_ip":"$(ap_ip)","clients":$(ap_clients),
"idle_min":$lim,"idle_left":$idle_left,
"on_confirm":${ON_CONFIRM:-5},"off_confirm":${OFF_CONFIRM:-120},
"batt":$(batt_json),
"adb_tcp":${ADB_TCP:-0},"adb_code":$(adb_tcp_code),"adb_port":"$(getprop service.adb.tcp.port)","adb_persist":"$(getprop persist.adb.tcp.port)",
"log_size":$(log_size "$LOG"),"log_old":$(log_size "$LOG1"),"log_max":${LOG_MAX:-3145728},"log_on":${LOG_ON:-1},
"url":"$(web_url)"}
EOF
}

start_web() {
  pgrep -f "httpd -f -p $PORT" >/dev/null 2>&1 && return 0
  # CGI 目录由 busybox httpd 固定映射为 $HOME/cgi-bin；api.sh 必须有执行位，
  # 否则 httpd 对 CGI 一律 404（首页却正常，很容易误判成路由问题）
  [ -x "$MODDIR/webroot/cgi-bin/api.sh" ] || chmod 755 "$MODDIR/webroot/cgi-bin/api.sh" 2>/dev/null
  $BB setsid $BB httpd -f -p "$PORT" -h "$MODDIR/webroot" > "$DATA/httpd.log" 2>&1 &
  sleep 1
  pgrep -f "httpd -f -p $PORT" > "$DATA/httpd.pid"
  if [ -s "$DATA/httpd.pid" ]; then
    log "控制台: 监听 $PORT，地址 $(web_url)"
  else
    log "控制台: 启动失败，httpd 日志 $($BB head -3 "$DATA/httpd.log" 2>/dev/null | $BB tr '\n' ' ')"
  fi
}

stop_web() {
  [ -f "$DATA/httpd.pid" ] && kill "$(cat "$DATA/httpd.pid")" 2>/dev/null
  pkill -f "httpd -f -p $PORT" 2>/dev/null
  rm -f "$DATA/httpd.pid" 2>/dev/null
}

# 守护进程每轮调一次，挂了就拉起来
ensure_web() {
  pgrep -f "httpd -f -p $PORT" >/dev/null 2>&1 || start_web
}
