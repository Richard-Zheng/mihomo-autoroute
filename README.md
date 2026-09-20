# meta-route

`meta-route` is a lightweight OpenWrt policy-routing script for Mihomo TUN setups.

It routes:

* LAN/private traffic directly
* China mainland traffic directly
* non-China traffic through Mihomo
* selected China IP prefixes through Mihomo when domain-aware routing is needed
* Mihomo proxy-node addresses directly, after resolving node server domains
* replies to connections initiated from WAN directly, including local services and port forwards

The kernel only performs coarse IP-based routing. Mihomo handles fine-grained `DIRECT` / `PROXY` decisions using SNI sniffing and domain rules.

## Overview

The script creates a dedicated routing table:

```text id="r1k4v1"
table 2026
```

with roughly this structure:

```text id="x22xqu"
LAN/private networks     → throw
China mainland prefixes → throw
everything else          → dev Meta
```

A `throw` route causes lookup to continue into the normal `main` routing table.

So the effective routing flow is:

- **LAN/China**: throw - main - WAN
- **other IP**: default dev Meta - Mihomo

Mihomo itself uses:

```yaml id="m3wl6v"
routing-mark: 6666
```

The script installs a higher-priority policy rule:

```text id="96k937"
fwmark 6666 → main
```

so Mihomo's outbound connections never loop back into its own TUN interface.

For public inbound services, a small firewall rule set records which
connections started on WAN. Use `meta-route-reply.nft` on fw4 or
`meta-route-reply-iptables.sh` on fw3. Their replies receive a separate mark
and use `main` before the destination-based Meta rule is considered.

---

## Requirements

Install:

```sh id="wd3k7k"
opkg update
opkg install ip-full resolveip
```

The script also requires either `wget` or `curl`.

OpenWrt normally includes `wget`.

Start `mihomo` and let it create a tun interface `Meta`.

Add the interface to OpenWrt's firewall. Other Linux system can omit this step:

```sh
uci add firewall zone
uci set firewall.@zone[-1].name='mihomo'
uci add_list firewall.@zone[-1].device='Meta'
uci set firewall.@zone[-1].input='ACCEPT'
uci set firewall.@zone[-1].output='ACCEPT'
uci set firewall.@zone[-1].forward='ACCEPT'

uci add firewall forwarding
uci set firewall.@forwarding[-1].src='lan'
uci set firewall.@forwarding[-1].dest='mihomo'

uci commit firewall
/etc/init.d/firewall restart
```

---

## Installation

Install the script as:

```text id="94b99g"
/usr/bin/meta-route.sh
```

Then:

```sh id="9rv4ob"
chmod +x /usr/bin/meta-route.sh
/usr/bin/meta-route.sh apply
```

### Deploy to OpenWrt

Run the deployment script from this repository:

```sh
./deploy.sh
```

The default target is `root@192.168.1.1`. Pass another SSH destination when
needed:

```sh
./deploy.sh root@openwrt.example
```

It installs `meta-route.sh`, its hotplug hook, and the Mihomo init script. It
detects the active firewall backend from `/etc/init.d/firewall`: on fw4 it
installs the nftables reply-mark include and runs `fw4 check`; on fw3 it
installs the iptables reply-mark script and its UCI firewall include. It then
restarts the firewall, enables and restarts Mihomo, and applies the policy
routes.

The script uses legacy SCP (`-O`) because many OpenWrt SSH servers do not
provide SFTP.

When exposing a service or forwarding a WAN port, new connections are tagged;
existing connections are not tagged retroactively.

#### fw4 / nftables

`deploy.sh` installs this include and runs `fw4 check` before restarting the
firewall. This include expects
the standard OpenWrt firewall zone named `wan`; it uses the zone's actual
devices, including PPPoE and VLAN devices.

#### fw3 / iptables

`deploy.sh` installs this script and adds its UCI firewall include. The script reads the default WAN
devices from the `main` IPv4 and IPv6 routing tables and installs idempotent
`mangle PREROUTING` and `mangle OUTPUT` rules. It requires the iptables
`conntrack`, `connmark`, `CONNMARK`, and `MARK` extensions. Use the same
iptables backend as fw3 (usually `iptables-legacy` on older OpenWrt). The
script assumes one active WAN whose return route is in `main`. `WAN4_DEV`
and `WAN6_DEV` can override device detection, but they do not solve
multiple-WAN return routing; that needs a separate table per WAN.

The script can also be run manually:

```sh
meta-route-reply-iptables.sh apply
meta-route-reply-iptables.sh status
meta-route-reply-iptables.sh clear
```

If SSH uses a non-default port, specify it with uppercase `-P` for `scp` and lowercase `-p` for `ssh`:

```sh
scp -O -P 2222 meta-route.sh root@192.168.1.1:/usr/bin/meta-route.sh
ssh -p 2222 root@192.168.1.1
```

### OpenWrt Hotplug

Install the included device hotplug script to apply the routing table whenever the `Meta` TUN device appears and clear it when the device disappears:

```sh
cp meta-route.hotplug /etc/hotplug.d/net/99-meta-route
chmod +x /etc/hotplug.d/net/99-meta-route
```

The script listens for OpenWrt `net` hotplug events:

```text
DEVICENAME=Meta ACTION=add     → meta-route.sh apply
DEVICENAME=Meta ACTION=remove  → meta-route.sh clear
```

It expects the main script at `/usr/bin/meta-route.sh`. If a different installation path is needed, change `META_ROUTE_SCRIPT` near the top of `meta-route.hotplug`.

---

## Why This Exists

A common Mihomo setup routes traffic according to DNS results.

This script deliberately avoids making DNS part of the main routing architecture.

Instead:

- Linux kernel: coarse IP routing
- Mihomo: SNI sniffing / fine-grained routing

This keeps the kernel routing layer simple and allows Mihomo's SNI `override-destination` to deal with DNS pollution or incorrect destination IPs.

---

## China IP Routing

China mainland IPv4 and IPv6 prefixes are downloaded from:

```text id="ho32h6"
https://ispip.clang.cn/all_cn_ipv46.txt
```

and cached at:

```text id="o3dnca"
/etc/meta-route/all_cn_ipv46.txt
```

Each downloaded prefix is installed as a `throw` route:

```text id="dqxiby"
throw 223.0.0.0/8 proto 66
```

The custom route protocol:

```text id="hyl3b2"
proto 66
```

marks routes originating from the China IP list.

Private and LAN routes do not use this protocol ID.

---

## Force-Meta Domains

Some domains resolve to China mainland addresses even though their traffic should still reach Mihomo.

A typical example is:

```text id="xoh0dk"
www.bing.com
```

Without special handling:

```text id="ai10f7"
www.bing.com
   ↓
China IP
   ↓
CN throw route
   ↓
main
   ↓
DIRECT
```

Mihomo never sees the connection, so SNI sniffing cannot help.

Configure such domains with:

```sh id="cbkrqv"
FORCE_META_DOMAINS="
www.bing.com
"
```

At startup, the script resolves each domain.

For example:

```text id="en8g5m"
www.bing.com
    ↓
202.89.233.100
```

It then asks the kernel which downloaded China prefix contains that address:

```text id="82hixg"
202.89.233.100
        ↓
202.89.232.0/21
```

and removes:

```text id="xjgvw5"
throw 202.89.232.0/21 proto 66
```

from the policy table.

The whole prefix now enters Mihomo:

```text id="64dygu"
202.89.232.0/21
        ↓
      Meta
        ↓
     Mihomo
        ↓
    SNI sniff
        ↓
 DIRECT / PROXY
```

This is intentionally done at prefix granularity instead of adding a single `/32` exception.

Addresses in the same prefix are often related to the same CDN or service provider, while Mihomo is better suited to make the final domain-level decision.

---

## Proxy Node Bypasses

The script reads proxy node `server` values from the top-level `proxies:` section of:

```text
/etc/mihomo/config.yaml
```

Node domains are resolved at the end of `apply`, after the complete base routing table and Force-Meta exceptions have been installed. Each resulting IPv4 or IPv6 address is installed as a host-sized `throw` route (`/32` or `/128`), allowing the node connection to continue through the normal `main` routing table instead of entering the `Meta` interface.

Set a different configuration path with the environment variable `MIHOMO_CONFIG`:

```sh
MIHOMO_CONFIG=/path/to/config.yaml meta-route.sh apply
```

This final step is best-effort: missing configuration files, DNS failures, and route-installation failures only produce warnings and do not fail `apply`. Run `refresh-domains` to resolve the node domains again and add their current addresses, or `apply` to rebuild all routes and discard stale addresses.

---

## Failsafe Design

The script is designed so optional features fail safely.

### DNS failure

Force-Meta domain resolution is best-effort.

The complete China routing table is installed first.

Only afterwards are Force-Meta exceptions applied.

If DNS is unavailable or slow:

```text id="7an0eu"
DNS timeout / failure
        ↓
skip Force-Meta processing
        ↓
original CN throw remains
        ↓
traffic may temporarily go DIRECT
```

The routing table itself remains valid.

In other words, a DNS failure can only cause some traffic to bypass Mihomo accidentally; it cannot cause unrelated China traffic to be redirected into Mihomo.

### China IP list failure

Updates are conservative:

```text id="z8vhsh"
download succeeds
        ↓
use new list

download fails
        ↓
valid cache exists
        ↓
use cached list

download fails
+ no valid cache
        ↓
abort before modifying routes
```

A suspiciously short download is also rejected instead of replacing a known-good cache.

---

## Mihomo Configuration

The TUN interface should be managed by Mihomo, but routing should be managed by this script.

Example:

```yaml id="ob8zq7"
routing-mark: 6666

tun:
  enable: true
  device: Meta
  auto-route: false
```

`auto-route` should remain disabled to avoid Mihomo installing a second, competing policy-routing configuration.

---

## Configuration

Configuration lives near the top of `meta-route.sh`.

### TUN interface

```sh id="4shzcu"
META_DEV="Meta"
```

### Routing table

```sh id="j3squa"
TABLE="2026"
```

### Mihomo routing mark

```sh id="vfwhxa"
MIHOMO_MARK="6666"
```

This must match:

```yaml id="j0xq6l"
routing-mark: 6666
```

### China route protocol ID

```sh id="uysnvw"
CN_PROTO="66"
```

This is only used internally to distinguish downloaded China routes from LAN/private routes.

### LAN interfaces

Default:

```sh id="do6085"
LAN_DEVS="br-lan"
```

Multiple interfaces:

```sh id="93jqyv"
LAN_DEVS="br-lan br-guest br-iot"
```

Directly connected prefixes on these interfaces are automatically bypassed.

### Force-Meta domains

```sh id="g2x7h3"
FORCE_META_DOMAINS="
bing.com
"
```

More domains can be added:

```sh id="qr32lu"
FORCE_META_DOMAINS="
bing.com
example.com
foo.example
"
```

---

## Private Networks

The following IPv4 ranges bypass Mihomo:

```text id="mhdknn"
0.0.0.0/8
10.0.0.0/8
100.64.0.0/10
127.0.0.0/8
169.254.0.0/16
172.16.0.0/12
192.168.0.0/16
224.0.0.0/4
240.0.0.0/4
```

IPv6:

```text id="4dxcl4"
::/128
::1/128
fc00::/7
fe80::/10
ff00::/8
```

These routes do not use `proto 66`, so Force-Meta processing cannot accidentally delete them.

For example, even if DNS incorrectly returns:

```text id="5lcpa5"
bing.com → 192.168.1.1
```

the private-network bypass remains untouched.

---

## Commands

Apply or rebuild everything:

```sh id="nslqui"
meta-route.sh apply
```

The following are aliases:

```sh id="ugjs8r"
meta-route.sh start
meta-route.sh update
meta-route.sh restart
```

Refresh Force-Meta domains and proxy-node domain bypasses:

```sh id="a5crs6"
meta-route.sh refresh-domains
```

Show current state:

```sh id="942ltw"
meta-route.sh status
```

Remove the policy-routing configuration:

```sh id="pfoosh"
meta-route.sh clear
```

or:

```sh id="cdreqa"
meta-route.sh stop
```

### Note on `refresh-domains`

For Force-Meta domains, `refresh-domains` only removes additional matching China prefixes. For proxy nodes, it adds or replaces routes for newly resolved addresses, but does not remove stale node addresses.

It does not restore prefixes removed by an earlier resolution.

Use:

```sh id="x44hx8"
meta-route.sh apply
```

to rebuild the table from scratch.

---

## Policy Rules

A typical rule set looks like:

```text id="id0vwc"
0:      from all lookup local
9990:   from all fwmark 0x40000000/0x40000000 lookup main
10000:  from all fwmark 0x1a0a lookup main
10010:  from all lookup 2026
32766:  from all lookup main
32767:  from all lookup default
```

`6666` is:

```text id="t5gxhz"
0x1a0a
```

in hexadecimal.

The important ordering is:

```text id="zqc6ss"
fwmark 6666
     ↓
    main
```

before:

```text id="uk1pr1"
normal traffic
     ↓
 table 2026
```

This prevents routing loops.

### Public inbound service replies

Both firewall integrations mark the conntrack entry when a new connection
arrives on WAN. They mark only packets in the reply direction before their
route lookup: forwarded replies in `PREROUTING`, and router-local replies in
`OUTPUT`. The `9990` rule sends them through `main`, preserving the WAN
return path and the port forward's reverse NAT. Other LAN traffic still follows
the usual China/Meta split.

The reply bit is `0x40000000` in both the conntrack mark and packet mark. It is
ORed into existing marks; reserve this bit if another policy-routing package
also uses marks. This setup assumes `main` routes back through the public WAN.
If you use multiple WANs, each ingress WAN needs its own mark and matching
return routing table to guarantee that replies leave through the same WAN.

---

## Example Routing Table

A simplified table might contain:

```text id="ckqzqy"
throw 10.0.0.0/8
throw 100.64.0.0/10
throw 192.168.0.0/16

throw 1.0.1.0/24 proto 66
throw 1.0.2.0/23 proto 66
throw 223.0.0.0/8 proto 66

default dev Meta
```

If:

```text id="jal6sp"
bing.com → 202.89.233.100
```

and:

```text id="d0or40"
202.89.232.0/21
```

is present in the China IP list, that `throw` route is removed.

The prefix then naturally falls through to:

```text id="h8f1hm"
default dev Meta
```

---

## Verification

### Foreign traffic should enter Mihomo

```sh id="42o5x3"
ip route get 8.8.8.8
```

Expected:

```text id="1cv525"
dev Meta
```

### China traffic should bypass Mihomo

```sh id="a3jdl6"
ip route get 223.5.5.5
```

It should ultimately use the normal WAN path.

### Verify Mihomo loop prevention

```sh id="71el01"
ip route get 8.8.8.8 mark 6666
```

This must use the normal route.

It must not contain:

```text id="98jg1c"
dev Meta
```

### Verify public-service return routing

```sh
ip -4 route get 8.8.8.8 mark 0x40000000
```

On fw4:

```sh
nft list chain inet fw4 meta_route_prerouting
nft list chain inet fw4 meta_route_output
```

On fw3:

```sh
meta-route-reply-iptables.sh status
```

The marked route must use WAN rather than `Meta`. For a port forward, test from
an external network and confirm the connection works with a client outside the
China IP list. The firewall rule counters should increase for the new inbound
connection and its replies. A working route lookup alone does not prove that
the firewall allows the inbound port or that the service is listening.

### Inspect the policy table

```sh id="pc09s7"
ip -4 route show table 2026
ip -6 route show table 2026
```

### Inspect China routes

```sh id="kjuw5e"
ip -4 route show table 2026 proto 66
ip -6 route show table 2026 proto 66
```

### Find the China prefix containing an IPv4 address

```sh id="cl8r9s"
ip -4 route show \
    table 2026 \
    match 202.89.233.100/32 \
    proto 66 \
    type throw
```

For IPv6:

```sh id="wxhkav"
ip -6 route show \
    table 2026 \
    match 2001:db8::1/128 \
    proto 66 \
    type throw
```

---

## Architecture

The complete design can be summarized as:

```text id="7s16n4"
                         Linux kernel
                              │
             ┌────────────────┼────────────────┐
             │                │                │
        LAN/private       ordinary CN        non-CN
             │                │                │
           main             main             Meta
                                                │
                                              Mihomo
                                                │
                                           SNI sniff
                                                │
                                     ┌──────────┴──────────┐
                                     │                     │
                                   DIRECT                PROXY
```

Force-Meta domains add one extra path:

```text id="1wup6p"
Force-Meta domain
       ↓
resolve address
       ↓
find containing CN prefix
       ↓
remove CN throw route
       ↓
whole prefix enters Meta
       ↓
Mihomo decides by domain
```

The responsibilities remain clean:

```text id="a9mlm2"
Kernel:
    "Does this IP need Mihomo?"

Mihomo:
    "What domain is this, and should it use DIRECT or PROXY?"
```

This keeps the routing layer small, predictable, and resilient to DNS or update failures.
