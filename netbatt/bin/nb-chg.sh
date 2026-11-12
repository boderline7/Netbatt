#!/system/bin/sh
# 充电执行器：只接收电量、温度与用户配置，输出“充/停”，并负责写节点与还原。
# 不判断车辆是否在用，也不改动热点决策依据。
# 依赖 nb-core.sh。

chg_active() { [ -f "$DATA/chg.on" ] && echo 1 || echo 0; }

# 首次安装默认开启；用户手动停止后 chg.off 跨重启保留
chg_init() {
  [ -f "$DATA/chg.on" ] || [ -f "$DATA/chg.off" ] || touch "$DATA/chg.on" 2>/dev/null
}

# root 下 [ -w ] 恒真，只能看权限位；取不到时退化成“写回原值”探测
chg_writable() {
  [ -f "$1" ] || return 1
  p=$(stat -c %A "$1" 2>/dev/null)
  case "$p" in
    *w*) return 0 ;;
    "")  ;;
    *)   return 1 ;;
  esac
  v=$(cat "$1" 2>/dev/null) || return 1
  printf '%s\n' "$v" > "$1" 2>/dev/null || return 1
  return 0
}

# 探测结果缓存。网页每 5 秒拉一次状态，探测会读写 sysfs，不能每次都探。
# 读不到缓存时立即可用；想强制重探就删掉这个文件。
chg_cache_load() {
  [ -f "$DATA/chg.node" ] || return 1
  . "$DATA/chg.node" 2>/dev/null
  [ -n "$CHG_NODE" ] && [ -e "$CHG_NODE" ]
}

chg_cache_save() {
  {
    echo "CHG_CH=$CHG_CH"
    echo "CHG_NODE=$CHG_NODE"
    echo "CHG_ON=$CHG_ON"
    echo "CHG_OFF=$CHG_OFF"
  } > "$DATA/chg.node" 2>/dev/null
}

# 判通道：CHG_CH=switch|soc|none，CHG_NODE=实际节点；switch 时一并定好极性。
#
# 两条通道的写入语义完全不同，不能按“谁先可写”来挑：
#   骁龙 input_suspend 类：0/1 = 允许/暂停充电
#   天玑 keep_chg_soc ：写目标电量，充到即停（写 0/1 毫无意义）
# 所以先按平台定优先级，再验证节点存在/可写，最后才走通用探测列表。
chg_detect() {
  chg_cache_load && return 0

  # 强制指定时也要节点存在，否则写进空路径等于永远没生效
  case "$CHG_MODE" in
    switch)
      if [ -e "$CHG_SWITCH" ]; then
        CHG_CH=switch; CHG_NODE=$CHG_SWITCH; chg_cache_save; return 0
      fi
      ;;
    soc)
      if [ -e "$SOC_PATH" ]; then
        CHG_CH=soc; CHG_NODE=$SOC_PATH; chg_cache_save; return 0
      fi
      ;;
  esac

  plat=$(chg_platform)
  if [ "$plat" = mtk ]; then
    # 天玑/联发科：目标电量通道
    if chg_writable "$SOC_PATH"; then
      CHG_CH=soc; CHG_NODE=$SOC_PATH; chg_cache_save; return 0
    fi
  else
    # 高通及其它：先试开关通道，语义是 0=充 1=停
    if chg_writable "$CHG_SWITCH"; then
      CHG_CH=switch; CHG_NODE=$CHG_SWITCH; CHG_ON=0; CHG_OFF=1
      chg_cache_save; return 0
    fi
  fi

  for spec in \
    "/sys/class/qcom-battery/input_suspend:0:1" \
    "/sys/class/power_supply/battery/input_suspend:0:1" \
    "/sys/class/power_supply/charger/charging_enabled:1:0" \
    "/sys/class/power_supply/battery/charging_enabled:1:0" \
    "/sys/class/power_supply/battery/batt_slate_mode:0:1" \
    "$SOC_PATH:::"
  do
    # 变量名不能用 p：chg_writable 内部也用 p，会把路径冲掉
    np=${spec%%:*}; r=${spec#*:}; non=${r%%:*}; noff=${r#*:}
    chg_writable "$np" || continue
    if [ "$np" = "$SOC_PATH" ]; then
      CHG_CH=soc; CHG_NODE=$np
    else
      CHG_CH=switch; CHG_NODE=$np; CHG_ON=$non; CHG_OFF=$noff
    fi
    chg_cache_save
    return 0
  done

  CHG_CH=none; CHG_NODE=""
  return 1
}

chg_platform() {
  b=$(getprop ro.board.platform 2>/dev/null)
  case "$b" in
    msm*|sdm*|sm[0-9]*|kona*|lahaina*|waipio*|taro*|blair*|sun*|cape*) echo qcom ;;
    mt[0-9]*|mtk*) echo mtk ;;
    *) [ -n "$b" ] && echo other || echo unknown ;;
  esac
}

# chg_apply on|off|restore —— 唯一碰硬件的地方
chg_apply() {
  chg_detect || return 1

  if [ "$CHG_CH" = soc ]; then
    [ -f "$DATA/soc.orig" ] || cat "$CHG_NODE" 2>/dev/null > "$DATA/soc.orig"
    case "$1" in
      off) v=$CHG_SOC_OFF ;;
      restore)
        v=$(cat "$DATA/soc.orig" 2>/dev/null)
        [ -z "$v" ] && v=$CHG_SOC_ON
        ;;
      *) v=$CHG_SOC_ON ;;
    esac
  else
    case "$1" in off) v=$CHG_OFF ;; *) v=$CHG_ON ;; esac
  fi

  [ "$(cat "$CHG_NODE" 2>/dev/null)" = "$v" ] && return 0
  printf '%s\n' "$v" > "$CHG_NODE" 2>/dev/null
  log "充电: 写入 $CHG_NODE=$v（$CHG_CH ${1}）"
}

# 周期采样：控制器关不关都记，采样是想看清整条充放电曲线
sample_once() {
  cap=$(cat "$BATT/capacity" 2>/dev/null); [ -z "$cap" ] && return 0
  st=$(cat "$BATT/status" 2>/dev/null); [ -z "$st" ] && st="?"
  rawt=$(cat "$BATT/temp" 2>/dev/null); [ -z "$rawt" ] && rawt=0
  t=$($BB awk -v t="$rawt" 'BEGIN{printf "%.1f", t/10}')
  cur=$(cat "$BATT/current_now" 2>/dev/null); [ -z "$cur" ] && cur=0
  case "$st" in
    Charging)    [ "$cur" -lt 0 ] && cur=$((cur * -1)) ;;
    Discharging) [ "$cur" -gt 0 ] && cur=$((cur * -1)) ;;
  esac
  vol=$(cat "$BATT/voltage_now" 2>/dev/null); [ -z "$vol" ] && vol=3800000
  [ "$vol" = 0 ] && vol=3800000
  watt=$($BB awk -v v="$vol" -v c="$cur" 'BEGIN{printf "%.2f", v*c/1e12}')
  case "$st" in
    Charging) dir=充 ;;
    Discharging) dir=放 ;;
    Full) dir=满 ;;
    *) dir=闲 ;;
  esac
  ma=$($BB awk -v c="$cur" 'BEGIN{printf "%d", c/1000}')
  sample_now "$cap" "$dir" "$watt" "$ma" "$t"
}

chg_once() {
  sample_once

  if [ ! -f "$DATA/chg.on" ]; then
    chg_apply restore >/dev/null 2>&1
    return 0
  fi

  cap=$(cat "$BATT/capacity" 2>/dev/null); [ -z "$cap" ] && return 0
  rawt=$(cat "$BATT/temp" 2>/dev/null); [ -z "$rawt" ] && rawt=0
  t=$((rawt / 10))

  if [ "$cap" -le 15 ]; then
    want=on
  elif [ "$t" -ge "$MAX_TEMP" ]; then
    want=off
  elif [ "$cap" -ge "$PAUSE_CAP" ]; then
    want=off
  elif [ "$cap" -le "$RESUME_CAP" ]; then
    want=on
  else
    want=$(cat "$DATA/chg.state" 2>/dev/null)
    [ -z "$want" ] && want=on
  fi

  prev=$($BB cat "$DATA/chg.state" 2>/dev/null)
  now=$(date '+%s')
  last=$($BB cat "$DATA/chg.last" 2>/dev/null)
  # 只在状态变化时写节点，避免每 10 秒无意义地刷 sysfs；
  # 另外每 10 分钟兜底重写一次，防止系统在插拔/息屏后把节点改回去。
  if [ "$prev" != "$want" ] || [ -z "$last" ] || [ $((now - last)) -ge 600 ]; then
    chg_apply "$want"
    printf '%s\n' "$now" > "$DATA/chg.last" 2>/dev/null
  fi
  echo "$want" > "$DATA/chg.state" 2>/dev/null
  if [ "$prev" != "$want" ]; then
    log "充电控制: ${prev:-?} -> $want（${cap}% ${t}℃ 上限 $PAUSE_CAP 恢复 $RESUME_CAP）"
  fi
  return 0
}

chg_ctl() {
  case "$1" in
    start)
      rm -f "$DATA/chg.off" 2>/dev/null
      touch "$DATA/chg.on" 2>/dev/null
      chg_once
      log "充电控制: 启动"
      ;;
    stop)
      rm -f "$DATA/chg.on" "$DATA/chg.last" 2>/dev/null
      touch "$DATA/chg.off" 2>/dev/null
      chg_apply restore
      echo on > "$DATA/chg.state" 2>/dev/null
      log "充电控制: 停止并还原硬件"
      ;;
    *) return 1 ;;
  esac
  return 0
}

# set_batt <上限> [下限]  下限省略时默认取 上限-5
set_batt() {
  p="$1"; r="$2"
  [ "$p" -ge 20 ] && [ "$p" -le 100 ] || return 1
  [ -z "$r" ] && r=$((p - 5))
  [ "$r" -ge 5 ] && [ "$r" -le 99 ] || return 1
  [ "$r" -lt "$p" ] || return 1
  cfg_set PAUSE_CAP "$p"
  cfg_set RESUME_CAP "$r"
  PAUSE_CAP=$p
  RESUME_CAP=$r
  log "充电阈值: 上限 $p% 恢复 $r%"
  chg_once
  return 0
}

batt_json() {
  cap=$(cat "$BATT/capacity" 2>/dev/null); [ -z "$cap" ] && cap=0
  st=$(cat "$BATT/status" 2>/dev/null); [ -z "$st" ] && st="unknown"
  rawt=$(cat "$BATT/temp" 2>/dev/null); [ -z "$rawt" ] && rawt=0
  temp=$($BB awk -v t="$rawt" 'BEGIN{printf "%.1f", t/10}')
  cur=$(cat "$BATT/current_now" 2>/dev/null); [ -z "$cur" ] && cur=0
  # 符号各平台不一致（vivo/MTK 充电时给负值），统一成 正=充入 负=放出
  case "$st" in
    Charging)    [ "$cur" -lt 0 ] && cur=$((cur * -1)) ;;
    Discharging) [ "$cur" -gt 0 ] && cur=$((cur * -1)) ;;
  esac
  ma=$($BB awk -v c="$cur" 'BEGIN{printf "%d", c/1000}')
  vol=$(cat "$BATT/voltage_now" 2>/dev/null); [ -z "$vol" ] && vol=3800000
  [ "$vol" = 0 ] && vol=3800000
  watt=$($BB awk -v v="$vol" -v c="$cur" 'BEGIN{printf "%.2f", v*c/1e12}')
  case "$st" in
    Charging) dir=chg ;;
    Discharging) dir=dis ;;
    Full) dir=full ;;
    *)
      if [ "$cur" -gt 30000 ]; then dir=chg
      elif [ "$cur" -lt -30000 ]; then dir=dis
      else dir=idle; fi
      ;;
  esac
  chg_detect >/dev/null 2>&1
  sw="?"; [ -n "$CHG_NODE" ] && sw=$(cat "$CHG_NODE" 2>/dev/null)
  printf '{"cap":%s,"status":"%s","temp":%s,"ma":%s,"w":%s,"dir":"%s","pc":%s,"rc":%s,"enabled":%s,"sw":"%s","state":"%s","ch":"%s","node":"%s","plat":"%s","mt":%s}' \
    "$cap" "$st" "$temp" "$ma" "$watt" "$dir" "$PAUSE_CAP" "$RESUME_CAP" "$(chg_active)" "$sw" \
    "$(cat "$DATA/chg.state" 2>/dev/null || echo on)" "$CHG_CH" "$CHG_NODE" "$(chg_platform)" "$MAX_TEMP"
}
