#!/system/bin/sh
# 决策层：只读配置、事实与用户操作，计算 HS_TARGET。
# 不读硬件、不写硬件。唯一例外是 nb_tick，它只负责按顺序调用采集/决策/执行。
# 依赖 nb-core.sh。

SUPPRESS=$DATA/suppress

# 手动覆盖：on/off 模式下点开关也要立刻生效，不能被模式当场盖回去。
# 覆盖一直有效，直到断电（只对“手动开”生效）或用户改模式；重启后自然失效。
FORCE=$DATA/hs.force

force_get() { $BB cat "$FORCE" 2>/dev/null | $BB head -1; }
force_set() { printf '%s\n' "$1" > "$FORCE" 2>/dev/null; }
force_clear() { rm -f "$FORCE" 2>/dev/null; }

hs_mode() { echo "${HS_MODE:-auto}"; }

suppress_get() { [ -f "$SUPPRESS" ] && echo 1 || echo 0; }

suppress_set() {
  [ -f "$SUPPRESS" ] && return 0
  : > "$SUPPRESS" 2>/dev/null
  log "决策: 抑制自动开启（$1）"
  return 0
}

suppress_clear() { rm -f "$SUPPRESS" 2>/dev/null; }

# 用户切换模式。AUTO/ON/OFF 都是用户的明确意图，切换时一律清掉抑制。
set_mode() {
  case "$1" in
    auto|on|off) ;;
    *) return 1 ;;
  esac
  cfg_set HS_MODE "$1"
  HS_MODE="$1"
  suppress_clear
  force_clear
  rm -f "$DATA/idle.since" 2>/dev/null
  log "决策: 模式 -> $1"
  nb_tick
}

# 用户手动开/关。auto 下用“抑制”表达，on/off 下用“覆盖”，两者都不会被下一轮规则盖掉。
set_hs() {
  want=$1
  power_read
  m=$(hs_mode)
  if [ "$m" = "auto" ]; then
    if [ "$want" = "1" ]; then suppress_clear; else suppress_set "手动关闭"; fi
  else
    # on/off 是持久意图，手动开关作为一次覆盖，直到断电或用户改模式
    force_set "$want"
    log "决策: 手动覆盖 -> $want（模式 $m）"
  fi
  HS_WHY="手动"
  # 手动操作跳过 30 秒冷却：刚被自动开过一次时，用户点“开”不该没反应
  hs_exec "$want" force
  # AUTO 且断电时的“手动开”是一次性动作，不立刻跑决策，否则当场就被关掉。
  # 下一轮（约 10 秒后）AUTO 规则生效，热点会自行关闭。
  if [ "$want" = "1" ] && [ "$POWER" = "0" ]; then
    return 0
  fi
  nb_tick
  return 0
}

# 主决策表，见 docs/热点决策表.md §4
decide_hs() {
  # 手动覆盖优先。断电时“手动开”失效并清掉覆盖，避免停好车还一直开着热点耗电
  f=$(force_get)
  if [ -n "$f" ]; then
    if [ "$f" = "1" ] && [ "$POWER" = "0" ]; then
      force_clear
      HS_TARGET=0; HS_WHY=断电
    else
      HS_TARGET=$f; HS_WHY=手动保持
    fi
    return 0
  fi
  case "$(hs_mode)" in
    on)
      if [ "$POWER" = "1" ]; then HS_TARGET=1; HS_WHY=有电
      else HS_TARGET=0; HS_WHY=断电; fi
      ;;
    off)
      HS_TARGET=0; HS_WHY=模式关闭
      ;;
    *)
      if [ "$POWER" = "0" ]; then
        HS_TARGET=0; HS_WHY=断电
      elif [ "$(suppress_get)" = "1" ]; then
        HS_TARGET=0; HS_WHY=保持关闭
      else
        HS_TARGET=1; HS_WHY=车用
      fi
      ;;
  esac
  return 0
}

# 空转保护：只在 AUTO 生效，ON 是用户明确要求不被空转关掉。
decide_idle() {
  [ "$(hs_mode)" = "auto" ] || { rm -f "$DATA/idle.since" 2>/dev/null; return 0; }
  [ "${AP_REAL:-0}" = "1" ] || { rm -f "$DATA/idle.since" 2>/dev/null; return 0; }

  lim=${IDLE_OFF_MIN:-0}
  case "$lim" in ''|*[!0-9]*) lim=0 ;; esac
  [ "$lim" -gt 0 ] || return 0

  if [ "${CLIENTS:-0}" -gt 0 ]; then
    rm -f "$DATA/idle.since" 2>/dev/null
    return 0
  fi

  now=$(date '+%s')
  t=$($BB cat "$DATA/idle.since" 2>/dev/null)
  [ -z "$t" ] && { printf '%s\n' "$now" > "$DATA/idle.since" 2>/dev/null; return 0; }
  case "$t" in ''|*[!0-9]*) t=$now ;; esac
  [ $((now - t)) -ge $((lim * 60)) ] || return 0

  rm -f "$DATA/idle.since" 2>/dev/null
  suppress_set "空转 ${lim} 分钟无设备"
  log "决策: 空转 ${lim} 分钟无设备，本次供电周期不再自动开启"
  return 0
}

# 调度：采集 -> 决策 -> 执行。守护进程和网页操作都走这里。
nb_tick() {
  nb_cfg_reload
  facts_collect
  [ "${POWER_DROPPED:-0}" = "1" ] && suppress_clear

  decide_idle
  decide_hs
  hs_exec "$HS_TARGET"

  chg_once
  return 0
}
