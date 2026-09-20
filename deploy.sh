#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${1:-root@192.168.1.1}"
REMOTE_STAGE="/tmp/meta-route-deploy-$$"

for file in meta-route.sh meta-route.hotplug mihomo.init meta-route-reply.nft meta-route-reply-iptables.sh; do
    [[ -f "$ROOT_DIR/$file" ]] || {
        printf 'Missing required file: %s\n' "$ROOT_DIR/$file" >&2
        exit 1
    }
done

command -v ssh >/dev/null || { echo 'ssh is required' >&2; exit 1; }
command -v scp >/dev/null || { echo 'scp is required' >&2; exit 1; }

cleanup() {
    ssh -o BatchMode=yes "$TARGET" \
        "rm -rf '$REMOTE_STAGE'" >/dev/null 2>&1 || true
}
trap cleanup EXIT

ssh -o BatchMode=yes "$TARGET" \
    "mkdir -p '$REMOTE_STAGE'"

scp -O \
    "$ROOT_DIR/meta-route.sh" \
    "$ROOT_DIR/meta-route.hotplug" \
    "$ROOT_DIR/mihomo.init" \
    "$ROOT_DIR/meta-route-reply.nft" \
    "$ROOT_DIR/meta-route-reply-iptables.sh" \
    "$TARGET:$REMOTE_STAGE/"

# This router's BusyBox shell has no bash, so use POSIX sh over SSH rather
# than ssh-run, which requires bash on the remote endpoint.
ssh -o BatchMode=yes "$TARGET" /bin/sh -s <<EOF
set -eu

stage='$REMOTE_STAGE'

cp "\$stage/meta-route.sh" /usr/bin/meta-route.sh
chmod 0755 /usr/bin/meta-route.sh
cp "\$stage/meta-route.hotplug" /etc/hotplug.d/net/99-meta-route
chmod 0755 /etc/hotplug.d/net/99-meta-route
cp "\$stage/mihomo.init" /etc/init.d/mihomo
chmod 0755 /etc/init.d/mihomo

if command -v fw4 >/dev/null 2>&1 && grep -q 'fw4' /etc/init.d/firewall; then
    backend=fw4
elif command -v fw3 >/dev/null 2>&1 && grep -q 'fw3' /etc/init.d/firewall; then
    backend=fw3
else
    echo 'Cannot determine whether the active firewall backend is fw3 or fw4' >&2
    exit 1
fi

case "\$backend" in
fw4)
    cp "\$stage/meta-route-reply.nft" /etc/nftables.d/meta-route-reply.nft
    chmod 0644 /etc/nftables.d/meta-route-reply.nft
    fw4 check
    ;;
fw3)
    cp "\$stage/meta-route-reply-iptables.sh" /usr/bin/meta-route-reply-iptables.sh
    chmod 0755 /usr/bin/meta-route-reply-iptables.sh
    if ! uci show firewall | grep -Fq "path='/usr/bin/meta-route-reply-iptables.sh'"; then
        uci add firewall include
        uci set firewall.@include[-1].type='script'
        uci set firewall.@include[-1].path='/usr/bin/meta-route-reply-iptables.sh'
        uci set firewall.@include[-1].reload='1'
        uci commit firewall
    fi
    ;;
esac

echo "Using \$backend reply-mark integration"
/etc/init.d/firewall restart
/etc/init.d/mihomo enable
/etc/init.d/mihomo restart
/usr/bin/meta-route.sh apply
EOF

echo "Deployed to $TARGET"
