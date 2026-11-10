#!/system/bin/sh
MODDIR=/data/adb/modules/netbatt
. "$MODDIR/bin/nb-lib.sh"

printf 'Content-Type: application/json\r\nCache-Control: no-store\r\n\r\n'

get() {
  echo "$QUERY_STRING" | $BB tr '&' '\n' | $BB sed -n "s/^$1=//p" | $BB head -1
}

a=$(get a)

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
  apply)
    apply
    echo '{"ok":1}'
    ;;
  *)
    echo '{"ok":0,"error":"unknown_action"}'
    ;;
esac
