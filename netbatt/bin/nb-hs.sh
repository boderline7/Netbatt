#!/system/bin/sh
# 热点执行器：只负责“让实际状态追上目标”，不参与任何决策。
# 依赖 nb-core.sh、nb-facts.sh。

AP_TRY=$DATA/ap.try

wait_for() {
  t=$1; fn=$2
  i=0; lim=$((t * 5))
  while [ "$i" -lt "$lim" ]; do
    $fn && return 0
    $BB sleep 0.2 2>/dev/null || sleep 1
    i=$((i + 1))
  done
  return 1
}

# 唯一的热点开关命令：交给特权应用调 TetheringManager（本模块带 TETHER_PRIVILEGED）。
# am 的 --ez 用 Boolean.parseBoolean 解析，"1" 会被当成 false，必须写 true/false。
hs_cmd() {
  case "$1" in
    0) on=false ;;
    *) on=true ;;
  esac
  log "执行: 请求热点 $1（${HS_WHY:-未知}）"
  am broadcast -n com.netbatt.console/.TetherReceiver --ei type 0 --ez on "$on" >/dev/null 2>&1
  # 系统是异步的，短等一拍；失败不阻塞，下一轮会补
  if [ "$on" = true ]; then wait_for 4 ap_is_up; else wait_for 4 ap_down; fi
  return 0
}

# 目标与实际相同就什么都不做；不同才发命令，并重新读一次实际状态。
# 第二个参数传 force 时跳过冷却（手动操作），自动重试仍然受 30 秒限制。
hs_exec() {
  want=${1:-0}
  force=$2
  real=$(ap_running)
  [ "$want" = "$real" ] && return 0

  if [ "$want" = "1" ]; then
    now=$(date '+%s')
    last=$($BB cat "$AP_TRY" 2>/dev/null)
    case "$last" in ''|*[!0-9]*) last=0 ;; esac
    # 30 秒冷却：系统偶尔自己收掉热点，别每轮重建把 TetheringManager 打崩
    if [ "$force" != "force" ]; then
      [ $((now - last)) -lt 30 ] && return 0
    fi
    printf '%s\n' "$now" > "$AP_TRY" 2>/dev/null
  fi

  hs_cmd "$want"

  new=$(ap_running)
  if [ "$new" = "$want" ]; then
    log "执行: 成功，实况 $new"
  else
    log "执行: 未生效，实况 $new，稍后重试"
  fi
  return 0
}
