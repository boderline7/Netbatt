#!/system/bin/sh
MODDIR=/data/adb/modules/netbatt
. "$MODDIR/bin/nb-lib.sh"

get() {
  echo "$QUERY_STRING" | $BB tr '&' '\n' | $BB sed -n "s/^$1=//p" | $BB head -1
}

a=$(get a)

# 日志走纯文本，其余接口回 JSON。full=1 时带附件头，车机上可以直接整份拷走。
if [ "$a" = log ]; then
  printf 'Content-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\n'
  [ "$(get full)" = 1 ] && printf 'Content-Disposition: attachment; filename="netbatt.log"\r\n'
  printf '\r\n'
else
  printf 'Content-Type: application/json\r\nCache-Control: no-store\r\n\r\n'
fi

case "$a" in
  status)
    status_json
    ;;
  setnet)
    p=$(get prefix); s=$(get start); e=$(get end)
    if ! echo "$p" | $BB grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'; then
      echo '{"ok":0,"error":"invalid"}'
      exit 0
    fi
    # 改网段会打断当前连接，先回包再异步执行
    echo '{"ok":1,"note":"applying"}'
    PREFIX_ARG="$p" START_ARG="$s" END_ARG="$e" \
      $BB setsid sh -c '. /data/adb/modules/netbatt/bin/nb-lib.sh; set_net "$PREFIX_ARG" "$START_ARG" "$END_ARG"' >/dev/null 2>&1 &
    ;;
  batt)
    p=$(get pause); r=$(get resume)
    if set_batt "$p" "$r"; then echo '{"ok":1}'; else echo '{"ok":0,"error":"invalid"}'; fi
    ;;
  chg)
    op=$(get op)
    if chg_ctl "$op"; then echo '{"ok":1}'; else echo '{"ok":0,"error":"bad_op"}'; fi
    ;;
  hs|hotspot)
    # 交给特权应用（TETHER_PRIVILEGED + TetheringManager）；浏览器也能直接开关
    ty=$(get type); on=$(get on)
    [ "$ty" = "usb" ] || ty=wifi
    if [ "$a" = "hotspot" ]; then v=1
    elif [ "$on" = "0" ]; then v=0
    else v=1; fi
    hs "$ty" "$v"
    echo '{"ok":1,"type":"'"$ty"'","on":'"$v"'}'
    ;;
  fwd)
    op=$(get op); p=$(get port)
    case "$op" in
      add)
        if fwd_add "$p"; then echo '{"ok":1}'; else echo '{"ok":0,"error":"invalid"}'; fi
        ;;
      del)
        fwd_del "$p"; echo '{"ok":1}'
        ;;
      *)
        echo "{\"ok\":1,\"fwd\":[$(fwd_list | $BB tr ' ' ',')]}"
        ;;
    esac
    ;;
  keep)
    kw=$(get wifi); ku=$(get usb)
    [ -n "$kw" ] && set_keep wifi "$kw" >/dev/null
    [ -n "$ku" ] && set_keep usb "$ku" >/dev/null
    echo "{\"ok\":1,\"keep_wifi\":$KEEP_WIFI,\"keep_usb\":$KEEP_USB}"
    ;;
  settings)
    am start -a android.settings.TETHER_SETTINGS >/dev/null 2>&1
    echo '{"ok":1}'
    ;;
  usbnet)
    v=$(get net)
    case "$v" in
      auto|rndis|ncm|ecm) ;;
      *) echo '{"ok":0,"error":"bad_net"}'; exit 0 ;;
    esac
    # 本机 gadget 没有这个 function 就别切，切了 USB 会直接掉线
    if [ "$v" != auto ]; then
      f=$(usb_funcs)
      [ -z "$f" ] || usb_has_func "$v" || { echo '{"ok":0,"error":"func_missing"}'; exit 0; }
    fi
    cfg_set USB_NET "$v"; USB_NET="$v"
    log "USB 网络类型: 配置 $v，实际生效 $(usb_net_pick)"
    echo '{"ok":1,"net":"'"$v"'","func":"'$(usb_net_pick)'"}'
    # 重建 gadget 会顺带把 adb 断 1-2 秒，先回包再异步做
    $BB setsid sh -c '. /data/adb/modules/netbatt/bin/nb-lib.sh
      [ "$(usb_online)" = 1 ] || exit 0
      [ "$(usb_off_flag)" = 0 ] || exit 0
      usb_apply_funcs "$(usb_net_pick)"
      wait_for 10 usb_iface_any
      apply' >/dev/null 2>&1 &
    ;;
  native)
    v=$(get on); [ "$v" = "1" ] || v=0
    cfg_set USB_NATIVE "$v"; USB_NATIVE="$v"
    log "USB 共享模式: native=$v（1=系统 tethering 全权，0=模块接管）"
    echo '{"ok":1,"native":'"$v"'}'
    ;;
  adbtcp)
    on=$(get on); p=$(get port)
    if [ "$on" = "0" ]; then
      adb_tcp_off
    else
      adb_tcp_on "$p" || { echo '{"ok":0,"error":"bad_port"}'; exit 0; }
    fi
    echo '{"ok":1,"code":'"$(adb_tcp_code)"',"port":"$(getprop service.adb.tcp.port)"}'
    ;;
  clearpersist)
    if adb_persist_clear; then echo '{"ok":1}'; else echo '{"ok":0,"error":"failed"}'; fi
    ;;
  apply)
    apply
    echo '{"ok":1}'
    ;;
  log)
    if [ "$(get full)" = 1 ]; then
      log_dump
    else
      log_tail "$(get n)"
    fi
    ;;
  logclear)
    log_clear
    echo '{"ok":1}'
    ;;
  *)
    echo '{"ok":0,"error":"unknown_action"}'
    ;;
esac
