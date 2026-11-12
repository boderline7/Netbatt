#!/system/bin/sh
MODDIR=/data/adb/modules/netbatt
. "$MODDIR/bin/nb-core.sh"
. "$MODDIR/bin/nb-facts.sh"
. "$MODDIR/bin/nb-decide.sh"
. "$MODDIR/bin/nb-hs.sh"
. "$MODDIR/bin/nb-chg.sh"
. "$MODDIR/bin/nb-adb.sh"
. "$MODDIR/bin/nb-web.sh"

get() {
  echo "$QUERY_STRING" | $BB tr '&' '\n' | $BB sed -n "s/^$1=//p" | $BB head -1
}

a=$(get a)

# 日志走纯文本，其余接口回 JSON
if [ "$a" = log ]; then
  printf 'Content-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\n\r\n'
else
  printf 'Content-Type: application/json\r\nCache-Control: no-store\r\n\r\n'
fi

case "$a" in
  status)
    status_json
    ;;
  mode)
    v=$(get v)
    if set_mode "$v"; then
      echo "{\"ok\":1,\"mode\":\"$v\"}"
    else
      echo '{"ok":0,"error":"bad_mode"}'
    fi
    ;;
  hs)
    v=$(get v); [ "$v" = "0" ] || v=1
    if set_hs "$v"; then
      echo "{\"ok\":1,\"ap\":$(ap_running),\"suppress\":$(suppress_get)}"
    else
      echo '{"ok":0,"error":"mode_not_auto"}'
    fi
    ;;
  batt)
    p=$(get pause); r=$(get resume)
    if set_batt "$p" "$r"; then echo '{"ok":1}'; else echo '{"ok":0,"error":"invalid"}'; fi
    ;;
  chg)
    op=$(get op)
    if chg_ctl "$op"; then echo '{"ok":1}'; else echo '{"ok":0,"error":"bad_op"}'; fi
    ;;
  adbtcp)
    on=$(get on); p=$(get port)
    if [ "$on" = "0" ]; then
      adb_tcp_off
    else
      adb_tcp_on "$p" || { echo '{"ok":0,"error":"bad_port"}'; exit 0; }
    fi
    echo "{\"ok\":1,\"code\":$(adb_tcp_code),\"port\":\"$(getprop service.adb.tcp.port)\"}"
    ;;
  clearpersist)
    if adb_persist_clear; then echo '{"ok":1}'; else echo '{"ok":0,"error":"failed"}'; fi
    ;;
  log)
    log_tail "$(get n)"
    ;;
  logclear)
    log_clear
    echo '{"ok":1}'
    ;;
  logdump)
    p=$(log_export)
    if [ -n "$p" ]; then
      echo "{\"ok\":1,\"path\":\"$p\"}"
    else
      echo '{"ok":0,"error":"export_failed"}'
    fi
    ;;
  logsw)
    v=$(get on); [ "$v" = "1" ] || v=0
    if [ "$v" = "1" ]; then
      cfg_set LOG_ON 1; LOG_ON=1
      log "日志记录: 开启"
    else
      log "日志记录: 关闭"
      cfg_set LOG_ON 0; LOG_ON=0
    fi
    echo "{\"ok\":1,\"log_on\":$v}"
    ;;
  *)
    echo '{"ok":0,"error":"unknown_action"}'
    ;;
esac
