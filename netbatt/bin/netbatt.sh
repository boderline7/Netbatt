#!/system/bin/sh
MODDIR=${0%/*}
. "$MODDIR/nb-lib.sh"

case "$1" in
  init)   chg_init ;;
  apply)  apply ;;
  chg)    chg_once ;;
  keep)   keepalive ;;
  web)    start_web ;;
  stop)   stop_web; stop_dnsmasq ;;
  status) status_json ;;
  *) echo "usage: netbatt.sh init|apply|chg|keep|web|stop|status" ;;
esac
