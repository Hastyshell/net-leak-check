#!/bin/bash
# Environment inventory: OS, Clash Verge / core, effective config facts, system DNS chain,
# other VPNs/tunnels and their routes, IPv6, Tailscale, Chrome policies. Read-only.
. "$(dirname "$0")/lib.sh"
need curl jq || exit 0

section "System"
tag INFO "$(sw_vers -productName 2>/dev/null) $(sw_vers -productVersion 2>/dev/null) $(uname -m)"

section "Clash Verge / core"
APP="/Applications/Clash Verge.app"
[ -d "$APP" ] && tag INFO "Clash Verge app $(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null)"
if api_ok; then
  tag INFO "core $(api /version | jq -r '.version') (controller: $API_MODE)"
else
  tag FAIL "mihomo controller not reachable (core not running, or unknown socket/port)"
fi
if [ -f "$VERGE_DIR/verge.yaml" ]; then
  for k in enable_tun_mode enable_system_proxy enable_dns_settings use_default_bypass system_proxy_bypass; do
    v=$(awk -v k="$k" 'index($0, k ": ") == 1 { sub(/^[^:]+: */, ""); print; exit }' "$VERGE_DIR/verge.yaml")
    tag INFO "verge.$k = ${v:-<unset>}"
  done
fi
if [ -f "$VERGE_DIR/profiles.yaml" ]; then
  cur=$(awk '/^current:/ {print $2}' "$VERGE_DIR/profiles.yaml")
  tag INFO "current profile uid: $cur"
fi
[ -f "$GEN_CFG" ] || tag WARN "generated config not found at $GEN_CFG"

section "Core runtime (/configs)"
if api_ok; then
  api /configs | jq -r '"mode=\(.mode) mixed-port=\(."mixed-port") ipv6=\(.ipv6) allow-lan=\(."allow-lan")",
    "tun.enable=\(.tun.enable) device=\(.tun.device // "-") stack=\(.tun.stack // "-") auto-route=\(.tun."auto-route") auto-detect-interface=\(.tun."auto-detect-interface")",
    "tun.dns-hijack=\(.tun."dns-hijack" // [] | join(",")) route-exclude=\(.tun."route-exclude-address" // [] | join(",")) inet6=\(.tun."inet6-address" // [] | join(","))"' |
    while read -r l; do tag INFO "$l"; done
  if tun_enabled; then
    api /configs | jq -e '.tun."dns-hijack" | index("tcp://any:53")' >/dev/null || tag WARN "TUN dns-hijack has no tcp://any:53 (DNS over TCP can bypass)"
    api /configs | jq -e '.tun."route-exclude-address" // [] | index("100.64.0.0/10")' >/dev/null ||
      tag INFO "TUN does not exclude 100.64.0.0/10 (matters only if Tailscale is used)"
  fi
fi

section "Clash DNS (generated config)"
DNSB=$(yaml_block dns)
if [ -z "$DNSB" ]; then
  tag WARN "no dns block in generated config"
else
  echo "$DNSB" >"$OUT/dns-block.yaml"
  em=$(echo "$DNSB" | awk '/enhanced-mode:/ {print $2; exit}')
  tag INFO "enhanced-mode=${em:-?}  (full block saved to $OUT/dns-block.yaml)"
  ns=$(echo "$DNSB" | awk '/^  nameserver:/ {on=1; next} on && /^  (- |  )/ {print; next} on {exit}' | sed 's/^ *- *//' | tr -d "\"'")
  if [ -z "$ns" ]; then
    tag FAIL "dns.nameserver is empty: mihomo falls back to a plaintext default; overseas names leak to that resolver"
  else
    tag INFO "nameserver: $(echo "$ns" | tr '\n' ' ')"
    echo "$ns" | grep -qE '#' || tag WARN "no nameserver is routed through a proxy (#group): unmatched overseas names are resolved from the local network"
    echo "$ns" | grep -qiE '^(system|dhcp)|114\.114|223\.5\.5|223\.6\.6|119\.29\.29|180\.76\.76|doh\.pub|alidns|dnspod' &&
      tag WARN "default nameserver includes a local/CN resolver: overseas names can leak to it"
  fi
  echo "$DNSB" | grep -qE '^  fallback:' && ! echo "$DNSB" | grep -qE '^  fallback: \[\]' &&
    tag INFO "fallback list present: check it is not a CN resolver"
  echo "$DNSB" | grep -q 'direct-nameserver:' && tag INFO "direct-nameserver set" ||
    tag INFO "no direct-nameserver: DIRECT targets reuse the default (overseas) resolver — CN-only edges may be wrong"
  echo "$DNSB" | grep -qE '^  ipv6: true' && tag INFO "dns.ipv6=true (AAAA answered)"
fi
yaml_block sniffer | grep -q 'enable: true' && tag INFO "sniffer enabled" || tag INFO "sniffer disabled: apps that bypass Clash DNS get IP-only routing"

section "Proxies / rules (live core)"
if api_ok; then
  api /proxies | jq -r '.proxies | to_entries[] | select(.value.type|test("^(Vmess|Vless|Trojan|Shadowsocks|ShadowsocksR|Hysteria2?|Tuic|WireGuard|Snell|AnyTLS|Http|Socks5)$")) |
    "\(.key)\t\(.value.type)\tudp=\(.value.udp)"' >"$OUT/nodes.tsv"
  n=$(wc -l <"$OUT/nodes.tsv" | tr -d ' ')
  nu=$(grep -c 'udp=false' "$OUT/nodes.tsv")
  tag INFO "$n nodes, $nu without UDP"
  [ "$nu" -gt 0 ] && tag WARN "nodes without udp: $(awk -F'\t' '/udp=false/ {printf "%s ", $1}' "$OUT/nodes.tsv")— UDP matched to them falls through to DIRECT (real IP via WebRTC/QUIC)"
  api /proxies | jq -r '.proxies | to_entries[] | select(.value.type=="Selector" or .value.type=="URLTest" or .value.type=="Fallback") | "\(.key) -> \(.value.now)"' |
    head -12 | while read -r l; do tag INFO "group $l"; done
  api /rules >"$OUT/rules.json"
  tag INFO "rules loaded: $(jq '.rules | length' "$OUT/rules.json")"
  jq -e '.rules[] | select(.type=="AND" and (.payload|test("udp";"i")) and (.payload|test("443")) and .proxy=="REJECT")' "$OUT/rules.json" >/dev/null &&
    tag INFO "QUIC (UDP 443) is rejected" || tag INFO "QUIC is not rejected"
  g=$(jq -r '.rules[] | select((.proxy|test("DIRECT|直连")) or .proxy=="DIRECT") | select(.payload|test("gstatic\\.com|googleapis\\.com|google\\.com")) | .payload' "$OUT/rules.json" 2>/dev/null | grep -cv '\.cn$')
  [ "${g:-0}" -gt 0 ] && tag WARN "$g Google domains are routed DIRECT (ACL4SSR GoogleCN). With overseas DNS these get blocked IPs (broken fonts/UI) unless direct-nameserver is a CN resolver"
fi

section "System proxy"
scutil --proxy | awk '/Enable|Proxy :|Port/ {print}' | tr -s ' ' | while read -r l; do tag INFO "$l"; done

section "System DNS chain (scutil --dns, first resolvers)"
scutil --dns | awk '/^resolver #/ {n++} n>=1 && n<=4' | grep -E 'resolver #|domain|nameserver|flags|order' | sed 's/^ *//' >"$OUT/dns-chain.txt"
cat "$OUT/dns-chain.txt" | head -24 | while read -r l; do tag INFO "$l"; done
first_ns=$(scutil --dns | awk '
  /^DNS configuration \(for scoped queries\)/ { exit }
  /^resolver #[0-9]+/ {
    if (in_res && dom == "" && ns != "" && (best_ord == "" || ord + 0 < best_ord + 0)) {
      best_ord = ord; best_ns = ns
    }
    in_res = 1; dom = ""; ns = ""; ord = 999999999; next
  }
  in_res && /^[[:space:]]*domain[[:space:]]*:/ { dom = $3 }
  in_res && /^[[:space:]]*nameserver\[0\][[:space:]]*:/ { ns = $3 }
  in_res && /^[[:space:]]*order[[:space:]]*:/ { ord = $3 }
  END {
    if (in_res && dom == "" && ns != "" && (best_ord == "" || ord + 0 < best_ord + 0)) {
      best_ns = ns
    }
    print best_ns
  }')
first_dom=""
tag INFO "effective catch-all resolver (lowest order) = $first_ns"
resolv_ns=$(awk '/^nameserver / {print $2; exit}' /etc/resolv.conf 2>/dev/null)
tag INFO "/etc/resolv.conf nameserver = ${resolv_ns:-<none>}"
if tun_enabled && [ -n "$resolv_ns" ] && [ "$resolv_ns" != "$(tun_dns)" ]; then
  tag WARN "/etc/resolv.conf points to $resolv_ns (not Clash $(tun_dns)): CLI tools reading /etc/resolv.conf (dig/Go/c-ares) may bypass Clash DNS"
fi
for k in $(printf 'list State:/Network/Service/[^/]+/DNS\nquit\n' | scutil | awk '{print $4}'); do
  d=$(printf 'show %s\nquit\n' "$k" | scutil)
  if echo "$d" | grep -q SupplementalMatchDomains && echo "$d" | awk '/SupplementalMatchDomains/ {on=1; next} on && /0 :/ {print; exit}' | grep -qE '0 : *$'; then
    srv=$(echo "$d" | awk '/ServerAddresses/ {on=1; next} on && /0 :/ {print $3; exit}')
    tag INFO "catch-all supplemental resolver: $k -> $srv"
    if tun_enabled && [ "$srv" != "$(tun_dns)" ] && [ "$first_ns" = "$srv" ]; then
      tag FAIL "a catch-all resolver ($k -> $srv) outranks Clash: system DNS bypasses the TUN hijack (TUN-only mode breaks, names leak)"
    fi
  fi
done
if tun_enabled; then
  case "$first_ns" in "$(tun_dns)" | 198.18.*) tag PASS "system resolver #1 points into the Clash TUN" ;; esac
fi
svc=$(scutil <<<"show State:/Network/Global/IPv4" | awk '/PrimaryService/ {print $3}')
hp=$(printf 'show Setup:/Network/Service/%s\nquit\n' "$svc" | scutil | awk -F' : ' '/UserDefinedName/ {print $2}')
[ -n "$hp" ] && tag INFO "primary service '$hp' DNS: $(networksetup -getdnsservers "$hp" 2>/dev/null | tr '\n' ' ')"
for ip in $(networksetup -getdnsservers "$hp" 2>/dev/null | grep -E '^[0-9.]+$'); do
  r=$(route -n get "$ip" 2>/dev/null | awk '/interface:/ {print $2}')
  if tun_enabled && [ -n "$r" ] && [ "$r" != "$(tun_device)" ]; then
    case "$first_ns" in "$(tun_dns)" | 198.18.*) tag INFO "system DNS $ip is pinned to $r (a VPN 'protected' route), harmless while resolver #1 is Clash" ;;
      *) tag WARN "system DNS $ip is routed via $r, not the TUN: queries to it skip Clash's DNS hijack (a VPN 'protected' route?)" ;; esac
  fi
done

section "Tunnels / other VPNs"
ifconfig | awk '/^utun[0-9]+:/ {i=$1} /inet / && i {print i, $2}' | while read -r l; do tag INFO "utun: $l"; done
ps axo comm | grep -iE 'corplink|feilian|tailscale|wireguard|openvpn|globalprotect|pangps|zscaler|easyconnect|anyconnect|forticlient|clash|mihomo|sing-box|v2ray|xray|surge|shadowrocket|stash' |
  sed 's#.*/##' | sort -u | while read -r p; do tag INFO "process: $p"; done
td=$(tun_device)
netstat -rn -f inet | awk -v td="$td" '$NF ~ /^utun/ && $NF != td {c[$NF]++} END {for (i in c) print i, c[i]}' | while read -r i c; do
  tag INFO "$c IPv4 routes via $i (not Clash's TUN): traffic to these prefixes bypasses Clash"
done
netstat -rn -f inet | awk '$3 ~ /H/ && $3 ~ /G/ && $NF ~ /^en/ {print $1}' | head -10 | while read -r h; do
  tag INFO "host route pinned to physical NIC: $h"
done
if [ -d /usr/local/corplink ]; then
  tag INFO "CorpLink (飞连) installed"
  L=/usr/local/corplink/logs/corplink.log
  if [ -r "$L" ]; then
    tail -c 3000000 "$L" | grep -a 'Client Config result' | tail -1 | sed 's/.*Client Config result: //' >"$OUT/corplink-client-config.json"
    jq -r '"CorpLink split: dns=\(.vpn_dns) \(.vpn_dns_backup)  split-domains=\(.vpn_dns_domain_split|length)  split-routes=\(.vpn_route_split|length)  vip=\(.central_dns.vip // "-")"' \
      "$OUT/corplink-client-config.json" 2>/dev/null | while read -r l; do tag INFO "$l (details: $OUT/corplink-client-config.json)"; done
  fi
fi
if command -v tailscale >/dev/null 2>&1 || [ -d /Applications/Tailscale.app ]; then
  tag INFO "Tailscale installed; 100.100.100.100 routed via $(route -n get 100.100.100.100 2>/dev/null | awk '/interface:/ {print $2}')"
else
  tag INFO "Tailscale not installed"
fi
printf 'list State:/Network/Service/ClashDNSGuard.*\nquit\n' | scutil | grep -q ClashDNSGuard && tag INFO "clash-dns-guard resolver keys present"

section "IPv6"
pif=$(phys_if)
g6=$(ifconfig "$pif" 2>/dev/null | awk '/inet6/ && !/fe80/ && !/temporary/ {print $2}' | head -1)
if [ -n "$g6" ]; then
  tag INFO "global IPv6 on $pif: $(mask_ip "$g6")"
else
  tag INFO "no global IPv6 on $pif (IPv6 bypass cannot be exercised on this network)"
fi

section "Chrome"
CH=$(ls -d "/Applications/Google Chrome.app" "$HOME/Applications/"*"/Google Chrome.app" "$HOME/Applications/Google Chrome.app" 2>/dev/null | head -1)
if [ -n "$CH" ]; then
  tag INFO "Chrome $(defaults read "$CH/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null) at $CH"
  for src in "/Library/Managed Preferences/com.google.Chrome" "/Library/Managed Preferences/$USER/com.google.Chrome" "/Library/Preferences/com.google.Chrome" com.google.Chrome; do
    for k in WebRtcIPHandling WebRtcIPHandlingPolicy DnsOverHttpsMode; do
      v=$(defaults read "$src" "$k" 2>/dev/null) && tag INFO "policy $k=$v ($src)"
    done
  done
  tag INFO "effective Chrome policy / WebRTC behaviour: run browser_check.sh (reads chrome://policy in a temp profile)"
else
  tag INFO "Chrome not found"
fi
