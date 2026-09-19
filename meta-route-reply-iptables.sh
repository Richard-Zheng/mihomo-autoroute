#!/bin/sh

# Install as /usr/bin/meta-route-reply-iptables.sh and register it as a fw3
# script include. It also accepts {apply|clear|status} when run manually.
set -u

PRE_CHAIN="META_ROUTE_REPLY_PRE"
OUT_CHAIN="META_ROUTE_REPLY_OUT"
REPLY_BIT="0x40000000"
REPLY_MASK="0x40000000/0x40000000"

die() {
  echo "[meta-route-reply] ERROR: $*" >&2
  exit 1
}

default_device() {
  ip "$1" -o route show table main default 2>/dev/null |
    awk '{
      for (i = 1; i < NF; i++) {
        if ($i == "dev") {
          print $(i + 1)
          exit
        }
      }
    }'
}

clear_family() {
  bin="$1"

  command -v "$bin" >/dev/null 2>&1 || return 0

  while "$bin" -t mangle -D PREROUTING -j "$PRE_CHAIN" 2>/dev/null; do :; done
  while "$bin" -t mangle -D OUTPUT -j "$OUT_CHAIN" 2>/dev/null; do :; done

  "$bin" -t mangle -F "$PRE_CHAIN" 2>/dev/null || :
  "$bin" -t mangle -X "$PRE_CHAIN" 2>/dev/null || :
  "$bin" -t mangle -F "$OUT_CHAIN" 2>/dev/null || :
  "$bin" -t mangle -X "$OUT_CHAIN" 2>/dev/null || :
}

ensure_chain() {
  bin="$1"
  chain="$2"

  "$bin" -t mangle -N "$chain" 2>/dev/null ||
    "$bin" -t mangle -S "$chain" >/dev/null 2>&1 ||
    die "Cannot create $bin mangle chain $chain"
}

apply_family() {
  bin="$1"
  wan_dev="$2"

  ensure_chain "$bin" "$PRE_CHAIN"
  ensure_chain "$bin" "$OUT_CHAIN"

  "$bin" -t mangle -F "$PRE_CHAIN" ||
    die "Cannot flush $bin chain $PRE_CHAIN"
  "$bin" -t mangle -F "$OUT_CHAIN" ||
    die "Cannot flush $bin chain $OUT_CHAIN"

  # Conntrack is available in mangle PREROUTING, before DNAT and routing.
  "$bin" -t mangle -A "$PRE_CHAIN" \
    -i "$wan_dev" -m conntrack --ctstate NEW,RELATED --ctdir ORIGINAL \
    -j CONNMARK --or-mark "$REPLY_BIT" ||
    die "Cannot mark connections arriving on $wan_dev"

  # Forwarded replies must receive the packet mark before route lookup.
  "$bin" -t mangle -A "$PRE_CHAIN" \
    -m conntrack --ctdir REPLY \
    -m connmark --mark "$REPLY_MASK" \
    -j MARK --or-mark "$REPLY_BIT" ||
    die "Cannot mark forwarded replies"

  # mangle OUTPUT reroutes locally generated packets after their mark changes.
  "$bin" -t mangle -A "$OUT_CHAIN" \
    -m conntrack --ctdir REPLY \
    -m connmark --mark "$REPLY_MASK" \
    -j MARK --or-mark "$REPLY_BIT" ||
    die "Cannot mark router-local replies"

  "$bin" -t mangle -C PREROUTING -j "$PRE_CHAIN" 2>/dev/null ||
    "$bin" -t mangle -I PREROUTING 1 -j "$PRE_CHAIN" ||
    die "Cannot attach $PRE_CHAIN to $bin PREROUTING"

  "$bin" -t mangle -C OUTPUT -j "$OUT_CHAIN" 2>/dev/null ||
    "$bin" -t mangle -I OUTPUT 1 -j "$OUT_CHAIN" ||
    die "Cannot attach $OUT_CHAIN to $bin OUTPUT"

  echo "[meta-route-reply] $bin: WAN device $wan_dev"
}

status_family() {
  bin="$1"

  command -v "$bin" >/dev/null 2>&1 || return 0
  echo "=== $bin mangle chains ==="
  "$bin" -t mangle -L "$PRE_CHAIN" -v -n 2>/dev/null || :
  "$bin" -t mangle -L "$OUT_CHAIN" -v -n 2>/dev/null || :
  "$bin" -t mangle -S PREROUTING 2>/dev/null | awk -v chain="$PRE_CHAIN" 'index($0, "-j " chain) { print }'
  "$bin" -t mangle -S OUTPUT 2>/dev/null | awk -v chain="$OUT_CHAIN" 'index($0, "-j " chain) { print }'
}

case "${1:-apply}" in
apply)
  command -v iptables >/dev/null 2>&1 || die "iptables is required"
  command -v ip >/dev/null 2>&1 || die "ip is required"

  wan4_dev="${WAN4_DEV:-$(default_device -4)}"
  [ -n "$wan4_dev" ] || die "No IPv4 default-route device in main; set WAN4_DEV"
  apply_family iptables "$wan4_dev"

  if command -v ip6tables >/dev/null 2>&1; then
    wan6_dev="${WAN6_DEV:-$(default_device -6)}"
    if [ -n "$wan6_dev" ]; then
      apply_family ip6tables "$wan6_dev"
    else
      clear_family ip6tables
    fi
  fi
  ;;
clear)
  clear_family iptables
  clear_family ip6tables
  ;;
status)
  status_family iptables
  status_family ip6tables
  ;;
*)
  echo "Usage: $0 {apply|clear|status}" >&2
  exit 1
  ;;
esac
