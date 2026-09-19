#!/bin/sh

set -u

URL="https://ispip.clang.cn/all_cn_ipv46.txt"

META_DEV="Meta"
TABLE="2026"

# mihomo routing-mark: 6666
MIHOMO_MARK="6666"

# Packet-mark bit set by the fw4 or fw3 reply rules on replies to WAN-originated
# connections. Keep it distinct from Mihomo's socket mark and other mark bits.
REPLY_MARK="0x40000000/0x40000000"
REPLY_RULE_PREF="9990"

# Routes imported from the CN IP list are tagged with this protocol ID.
# This lets us distinguish them from LAN/private throw routes.
CN_PROTO="66"

MARK_RULE_PREF="10000"
META_RULE_PREF="10010"

CACHE_DIR="/etc/meta-route"
CN_FILE="$CACHE_DIR/all_cn_ipv46.txt"

# Resolved addresses of proxy nodes in this Mihomo configuration are
# installed as host-sized throw routes so Mihomo can reach them directly.
MIHOMO_CONFIG="${MIHOMO_CONFIG:-/etc/mihomo/config.yaml}"

# DNS lookup timeout for each force-Meta domain.
RESOLVE_TIMEOUT="3"

# Add all LAN-facing interfaces here.
LAN_DEVS="${LAN_DEVS:-br-lan}"

# If one of these domains resolves into a CN prefix, remove that entire
# CN prefix from the bypass table so the whole prefix reaches Mihomo.
FORCE_META_DOMAINS="
www.bing.com
bing.com
"

log() {
  logger -t meta-route "$*"
  echo "[meta-route] $*"
}

warn() {
  logger -t meta-route "WARNING: $*"
  echo "[meta-route] WARNING: $*" >&2
}

die() {
  logger -t meta-route "ERROR: $*"
  echo "[meta-route] ERROR: $*" >&2
  exit 1
}

ipv6_enabled() {
  [ -f /proc/sys/net/ipv6/conf/all/disable_ipv6 ] || return 1
  [ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6)" = "0" ]
}

check_requirements() {
  command -v ip >/dev/null 2>&1 ||
    die "'ip' is missing; install ip-full"

  command -v resolveip >/dev/null 2>&1 ||
    die "'resolveip' is missing; install resolveip"

  mkdir -p "$CACHE_DIR" ||
    die "Cannot create $CACHE_DIR"
}

wait_for_meta() {
  i=0

  while [ "$i" -lt 30 ]; do
    if ip link show dev "$META_DEV" >/dev/null 2>&1; then
      return 0
    fi

    i=$((i + 1))
    sleep 1
  done

  die "Interface $META_DEV does not exist"
}

download_cn_list() {
  tmp="$CN_FILE.tmp"
  clean="$CN_FILE.clean"

  rm -f "$tmp" "$clean"

  log "Downloading CN IP list..."

  if command -v curl >/dev/null 2>&1; then
    curl -fL \
      --connect-timeout 10 \
      --max-time 30 \
      --retry 2 \
      "$URL" \
      -o "$tmp"
    rc=$?
  elif command -v wget >/dev/null 2>&1; then
    wget \
      -T 15 \
      -O "$tmp" \
      "$URL"
    rc=$?
  else
    die "Neither curl nor wget is available"
  fi

  if [ "$rc" -ne 0 ]; then
    rm -f "$tmp"

    if [ -s "$CN_FILE" ]; then
      warn "Download failed; using cached CN IP list"
      return 0
    fi

    die "Failed to download CN IP list and no cache exists"
  fi

  tr -d '\r' <"$tmp" |
    awk '
            /^[[:space:]]*#/ { next }
            /^[[:space:]]*$/ { next }
            $1 ~ /\// { print $1 }
        ' >"$clean"

  rm -f "$tmp"

  count="$(wc -l <"$clean")"

  # Fail closed with respect to configuration changes:
  # never replace a known-good cache with a suspiciously short file.
  if [ "$count" -lt 1000 ]; then
    rm -f "$clean"

    if [ -s "$CN_FILE" ]; then
      warn "Downloaded CN list looks invalid ($count entries); using cache"
      return 0
    fi

    die "Downloaded CN list looks invalid ($count entries)"
  fi

  mv "$clean" "$CN_FILE"

  log "CN IP list updated: $count prefixes"
}

build_v4_batch() {
  file="$1"

  #
  # Addresses that should never be sent into Mihomo merely because
  # they are not present in the CN IP database.
  #
  cat >"$file" <<EOF
route replace throw 0.0.0.0/8 table $TABLE
route replace throw 10.0.0.0/8 table $TABLE
route replace throw 100.64.0.0/10 table $TABLE
route replace throw 127.0.0.0/8 table $TABLE
route replace throw 169.254.0.0/16 table $TABLE
route replace throw 172.16.0.0/12 table $TABLE
route replace throw 192.168.0.0/16 table $TABLE
route replace throw 224.0.0.0/4 table $TABLE
route replace throw 240.0.0.0/4 table $TABLE
EOF

  #
  # CN routes are tagged with proto $CN_PROTO.
  #
  awk -v table="$TABLE" -v proto="$CN_PROTO" '
        index($1, ":") == 0 && $1 ~ /\// {
            print "route replace throw " $1 \
                  " table " table \
                  " proto " proto
        }
    ' "$CN_FILE" >>"$file"

  #
  # Also bypass directly-connected LAN prefixes.
  #
  for dev in $LAN_DEVS; do
    ip -4 route show dev "$dev" scope link 2>/dev/null |
      awk -v table="$TABLE" '
                $1 != "default" &&
                $1 ~ /^[0-9]/ &&
                $1 ~ /\// {
                    print "route replace throw " $1 \
                          " table " table
                }
            ' >>"$file"
  done

  echo "route replace default dev $META_DEV table $TABLE" >>"$file"
}

build_v6_batch() {
  file="$1"

  cat >"$file" <<EOF
route replace throw ::/128 table $TABLE
route replace throw ::1/128 table $TABLE
route replace throw fc00::/7 table $TABLE
route replace throw fe80::/10 table $TABLE
route replace throw ff00::/8 table $TABLE
EOF

  awk -v table="$TABLE" -v proto="$CN_PROTO" '
        index($1, ":") != 0 && $1 ~ /\// {
            print "route replace throw " $1 \
                  " table " table \
                  " proto " proto
        }
    ' "$CN_FILE" >>"$file"

  for dev in $LAN_DEVS; do
    ip -6 route show dev "$dev" 2>/dev/null |
      awk -v table="$TABLE" '
                $1 != "default" &&
                index($1, ":") != 0 &&
                $1 ~ /\// {
                    print "route replace throw " $1 \
                          " table " table
                }
            ' >>"$file"
  done

  echo "route replace default dev $META_DEV table $TABLE" >>"$file"
}

exclude_cn_prefix_for_ip() {
  addr="$1"

  case "$addr" in
  *:*)
    family="-6"
    host="$addr/128"
    ;;
  *)
    family="-4"
    host="$addr/32"
    ;;
  esac

  #
  # "match host" returns every route whose prefix contains this host.
  #
  # Restricting the lookup to:
  #
  #     proto $CN_PROTO
  #     type throw
  #
  # guarantees that LAN/private throw routes cannot be removed.
  #
  ip "$family" route show \
    table "$TABLE" \
    match "$host" \
    proto "$CN_PROTO" \
    type throw \
    2>/dev/null |
    while read -r type prefix rest; do
      [ "$type" = "throw" ] || continue
      [ -n "$prefix" ] || continue

      log "Excluding CN prefix $prefix because it contains $addr"

      ip "$family" route del \
        throw "$prefix" \
        table "$TABLE" \
        proto "$CN_PROTO" \
        2>/dev/null ||
        warn "Failed to remove CN prefix $prefix"
    done
}

exclude_force_meta_domains() {
  for domain in $FORCE_META_DOMAINS; do
    log "Resolving force-Meta domain: $domain"

    #
    # This whole step is intentionally best-effort.
    #
    # Failure or timeout leaves the original CN throw routes intact,
    # so the worst case is that this domain is temporarily routed
    # directly instead of through Mihomo.
    #
    addresses="$(
      resolveip -t "$RESOLVE_TIMEOUT" "$domain" 2>/dev/null
    )"

    if [ -z "$addresses" ]; then
      warn "Could not resolve $domain; leaving CN routes unchanged"
      continue
    fi

    printf '%s\n' "$addresses" |
      sort -u |
      while IFS= read -r addr; do
        [ -n "$addr" ] || continue

        log "$domain -> $addr"
        exclude_cn_prefix_for_ip "$addr"
      done
  done
}

list_node_servers() {
  [ -r "$MIHOMO_CONFIG" ] || return 0

  # Read only server fields below the top-level "proxies" key. This avoids
  # treating DNS servers, provider URLs, and other unrelated server fields as
  # proxy nodes. Both quoted and unquoted scalar values are accepted.
  awk '
        /^[[:space:]]*#/ { next }

        /^[^[:space:]]/ {
            in_proxies = ($0 ~ /^proxies[[:space:]]*:/)
            next
        }

        in_proxies && $0 ~ /(^|[,{[:space:]])server[[:space:]]*:/ {
            value = $0
            sub(/^.*(^|[,{[:space:]])server[[:space:]]*:[[:space:]]*/, "", value)

            if (value ~ /^"/) {
                sub(/^"/, "", value)
                sub(/".*$/, "", value)
            } else if (value ~ /^\047/) {
                sub(/^\047/, "", value)
                sub(/\047.*$/, "", value)
            } else {
                sub(/[},].*$/, "", value)
            }

            sub(/[[:space:]]+#.*$/, "", value)
            sub(/[[:space:]]+$/, "", value)

            if (value != "") print value
        }
    ' "$MIHOMO_CONFIG" |
    sort -u
}

resolve_node_servers() {
  output="$1"
  : >"$output"

  if [ ! -r "$MIHOMO_CONFIG" ]; then
    warn "Mihomo config is not readable: $MIHOMO_CONFIG; skipping node bypasses"
    return 0
  fi

  servers="$(list_node_servers)"

  if [ -z "$servers" ]; then
    log "No proxy node servers found in $MIHOMO_CONFIG"
    return 0
  fi

  printf '%s\n' "$servers" |
    while IFS= read -r server; do
      [ -n "$server" ] || continue
      log "Resolving proxy node server: $server"

      addresses="$(resolveip -t "$RESOLVE_TIMEOUT" "$server" 2>/dev/null)"

      if [ -z "$addresses" ]; then
        warn "Could not resolve proxy node server $server; skipping its bypass"
        continue
      fi

      printf '%s\n' "$addresses" |
        awk '
              /^[0-9A-Fa-f:.]+$/ && (index($0, ".") || index($0, ":")) {
                  print
              }
            ' >>"$output"
    done

  sort -u "$output" -o "$output"
  count="$(wc -l <"$output")"
  log "Resolved $count unique proxy node addresses for bypass"
}

install_node_bypasses() {
  addresses_file="$1"

  while IFS= read -r addr; do
    [ -n "$addr" ] || continue

    case "$addr" in
    *:*)
      ipv6_enabled || continue
      family="-6"
      host="$addr/128"
      ;;
    *) family="-4"; host="$addr/32" ;;
    esac

    ip "$family" route replace throw "$host" table "$TABLE" 2>/dev/null ||
      warn "Failed to install proxy node bypass for $addr"
  done <"$addresses_file"
}

install_routes() {
  v4_batch="/tmp/meta-route-v4.$$"
  v6_batch="/tmp/meta-route-v6.$$"
  node_addresses="/tmp/meta-route-nodes.$$"

  trap 'rm -f "$v4_batch" "$v6_batch" "$node_addresses"' EXIT INT TERM

  log "Building routing table..."

  build_v4_batch "$v4_batch"

  if ipv6_enabled; then
    build_v6_batch "$v6_batch"
  fi

  #
  # Only modify the live routing table after:
  #
  #   - Meta exists
  #   - the CN list was successfully downloaded or a valid cache exists
  #   - batch files were generated
  #
  ip -4 route flush table "$TABLE" 2>/dev/null

  ip -4 -batch "$v4_batch" ||
    die "Failed to install IPv4 routes"

  if ipv6_enabled; then
    ip -6 route flush table "$TABLE" 2>/dev/null

    ip -6 -batch "$v6_batch" ||
      die "Failed to install IPv6 routes"
  fi

  #
  # Best-effort post-processing.
  #
  exclude_force_meta_domains

  # Resolve and install proxy-node bypasses last. Both DNS and route failures
  # are non-fatal: the complete base table remains usable if this step fails.
  resolve_node_servers "$node_addresses"
  install_node_bypasses "$node_addresses"

  rm -f "$v4_batch" "$v6_batch" "$node_addresses"
  trap - EXIT INT TERM

  log "Routing table installed"
}

remove_rules() {
  while ip -4 rule del \
    pref "$REPLY_RULE_PREF" \
    fwmark "$REPLY_MARK" \
    lookup main \
    2>/dev/null; do
    :
  done

  while ip -6 rule del \
    pref "$REPLY_RULE_PREF" \
    fwmark "$REPLY_MARK" \
    lookup main \
    2>/dev/null; do
    :
  done

  while ip -4 rule del \
    pref "$MARK_RULE_PREF" \
    fwmark "$MIHOMO_MARK" \
    lookup main \
    2>/dev/null; do
    :
  done

  while ip -4 rule del \
    pref "$META_RULE_PREF" \
    lookup "$TABLE" \
    2>/dev/null; do
    :
  done

  while ip -6 rule del \
    pref "$MARK_RULE_PREF" \
    fwmark "$MIHOMO_MARK" \
    lookup main \
    2>/dev/null; do
    :
  done

  while ip -6 rule del \
    pref "$META_RULE_PREF" \
    lookup "$TABLE" \
    2>/dev/null; do
    :
  done
}

install_rules() {
  remove_rules

  # Replies to WAN-originated connections keep the path of the incoming
  # connection. This must precede the catch-all Meta routing rule.
  ip -4 rule add \
    pref "$REPLY_RULE_PREF" \
    fwmark "$REPLY_MARK" \
    lookup main

  #
  # Loop prevention:
  #
  # mihomo outbound sockets carry routing-mark 6666 and therefore
  # bypass table $TABLE completely.
  #
  ip -4 rule add \
    pref "$MARK_RULE_PREF" \
    fwmark "$MIHOMO_MARK" \
    lookup main

  ip -4 rule add \
    pref "$META_RULE_PREF" \
    lookup "$TABLE"

  if ipv6_enabled; then
    ip -6 rule add \
      pref "$REPLY_RULE_PREF" \
      fwmark "$REPLY_MARK" \
      lookup main

    ip -6 rule add \
      pref "$MARK_RULE_PREF" \
      fwmark "$MIHOMO_MARK" \
      lookup main

    ip -6 rule add \
      pref "$META_RULE_PREF" \
      lookup "$TABLE"
  fi

  log "Policy rules installed"
}

apply() {
  check_requirements

  #
  # Do all potentially-failing preparation before changing routes.
  #
  wait_for_meta
  download_cn_list

  install_routes
  install_rules

  log "Meta routing enabled"
}

clear_routes() {
  log "Removing Meta routing..."

  remove_rules

  ip -4 route flush table "$TABLE" 2>/dev/null
  ip -6 route flush table "$TABLE" 2>/dev/null

  log "Meta routing disabled"
}

refresh_domains() {
  check_requirements

  node_addresses="/tmp/meta-route-nodes.$$"
  trap 'rm -f "$node_addresses"' EXIT INT TERM

  #
  # Force-Meta refresh only removes additional CN routes, while node
  # bypasses are added or replaced with their latest resolved addresses.
  #
  # It never restores routes removed by a previous resolution. A full
  # 'apply' reconstructs the table from the CN list from scratch.
  #
  exclude_force_meta_domains
  resolve_node_servers "$node_addresses"
  install_node_bypasses "$node_addresses"

  rm -f "$node_addresses"
  trap - EXIT INT TERM
}

status() {
  echo "=== Meta interface ==="
  ip link show dev "$META_DEV" 2>/dev/null || true

  echo
  echo "=== IPv4 policy rules ==="
  ip -4 rule show

  echo
  echo "=== IPv4 table $TABLE ==="
  ip -4 route show table "$TABLE"

  if ipv6_enabled; then
    echo
    echo "=== IPv6 policy rules ==="
    ip -6 rule show

    echo
    echo "=== IPv6 table $TABLE ==="
    ip -6 route show table "$TABLE"
  fi
}

case "${1:-apply}" in
apply | start | update | restart)
  apply
  ;;

refresh-domains)
  refresh_domains
  ;;

clear | stop)
  check_requirements
  clear_routes
  ;;

status)
  check_requirements
  status
  ;;

*)
  echo "Usage: $0 {apply|update|restart|refresh-domains|clear|status}"
  exit 1
  ;;
esac
