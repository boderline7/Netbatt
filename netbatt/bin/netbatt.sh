#!/system/bin/sh
MODDIR=${0%/*}
. "$MODDIR/nb-lib.sh"

case "$1" in
  init)   chg_init; dhcp_recover ;;
  apply)  apply ;;
  chg)    chg_once ;;
  keep)   keepalive ;;
  web)    start_web ;;
  stop)   stop_web; stop_dnsmasq ;;
  status) status_json ;;
  recover) dhcp_recover ;;
  *) echo "usage: netbatt.sh init|apply|chg|keep|web|stop|status|recover" ;;
esac
