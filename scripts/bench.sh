#!/bin/bash
# Per-node latency / throughput / exit, measured in a throw-away mihomo instance that is BOUND TO THE
# PHYSICAL NIC (interface-name), so its traffic does not get re-captured by the main core's TUN
# (otherwise every node is silently tunnelled through the currently selected one).
# Usage: bench.sh [node ...]   (default: every proxy node)   Needs: yq, the mihomo core binary.
. "$(dirname "$0")/lib.sh"
need curl jq yq || exit 0
[ -f "$GEN_CFG" ] || { tag SKIP "generated config not found"; exit 0; }
CORE=""
for c in "/Applications/Clash Verge.app/Contents/MacOS/verge-mihomo" "$(command -v mihomo 2>/dev/null)"; do
  [ -n "$c" ] && [ -x "$c" ] && { CORE=$c; break; }
done
[ -z "$CORE" ] && { tag SKIP "mihomo core binary not found"; exit 0; }

SB="$OUT/bench"; mkdir -p "$SB"
for f in geoip.dat geosite.dat Country.mmdb ASN.mmdb; do [ -f "$VERGE_DIR/$f" ] && cp -n "$VERGE_DIR/$f" "$SB/" 2>/dev/null; done
read -r MP CP <<<"$(python3 -I -c 'import socket
p=[]
for _ in range(2):
  s=socket.socket();s.bind(("127.0.0.1",0));p.append(s.getsockname()[1])
print(*p)')"
IF=$(phys_if)
yq ".tun.enable=false | .mode=\"global\" | .[\"mixed-port\"]=$MP | .[\"external-controller\"]=\"127.0.0.1:$CP\" |
    del(.[\"external-controller-unix\"]) | .secret=\"\" | .[\"interface-name\"]=\"$IF\" | .[\"log-level\"]=\"warning\" |
    del(.port) | del(.[\"socks-port\"]) | del(.[\"redir-port\"]) | del(.[\"tproxy-port\"]) | .[\"allow-lan\"]=false" "$GEN_CFG" >"$SB/config.yaml"
chmod 600 "$SB/config.yaml"
"$CORE" -d "$SB" -f "$SB/config.yaml" >"$SB/core.log" 2>&1 &
CPID=$!
trap 'kill $CPID 2>/dev/null; rm -f "$SB/config.yaml"' EXIT
for _ in $(seq 1 20); do curl -s --noproxy '*' "http://127.0.0.1:$CP/version" >/dev/null && break; sleep 0.5; done
curl -s --noproxy '*' "http://127.0.0.1:$CP/version" >/dev/null || { tag FAIL "bench core did not start: $(tail -2 "$SB/core.log")"; exit 0; }

nodes=$(printf '%s\n' "$@")
[ -z "$nodes" ] && nodes=$(curl -s --noproxy '*' "http://127.0.0.1:$CP/proxies" | jq -r '.proxies | to_entries[] |
  select(.value.type|test("^(Vmess|Vless|Trojan|Shadowsocks|ShadowsocksR|Hysteria2?|Tuic|WireGuard|Snell|AnyTLS|Http|Socks5)$")) | .key')
section "Nodes (bound to $IF; 2 MB from speed.cloudflare.com, 2 runs)"
enc() { python3 -I -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))' "$1"; }
echo "$nodes" | while read -r n; do
  [ -z "$n" ] && continue
  code=$(curl -s --noproxy '*' -o /dev/null -w '%{http_code}' -X PUT "http://127.0.0.1:$CP/proxies/GLOBAL" -d "{\"name\":\"$n\"}")
  [ "$code" = 204 ] || { tag WARN "$n: cannot select (HTTP $code) — unknown node name?"; continue; }
  d=$(curl -s --noproxy '*' "http://127.0.0.1:$CP/proxies/$(enc "$n")/delay?timeout=6000&url=https%3A%2F%2Fwww.gstatic.com%2Fgenerate_204" | jq -r '.delay // .message')
  s=""
  for _ in 1 2; do
    s="$s $(curl -s -m 20 -x "http://127.0.0.1:$MP" -o /dev/null -w '%{speed_download}' 'https://speed.cloudflare.com/__down?bytes=2000000' | awk '{printf "%.0fKB/s", $1/1024}')"
  done
  ex=$(curl -s -m 10 -x "http://127.0.0.1:$MP" https://www.cloudflare.com/cdn-cgi/trace | awk -F= '/^ip=/ {ip=$2} /^loc=/ {loc=$2} END {print ip, loc}')
  if [ -z "${ex% *}" ]; then
    tag WARN "$n  delay=$d  unreachable (no exit through this node)"
    continue
  fi
  cls=$(classify_ip "${ex% *}")
  [ "${cls%~}" = HOME ] && tag WARN "$n: exit is the HOME IP — node not actually used"
  tag INFO "$n  delay=$d  speed=[$s ]  exit=$(mask_ip "${ex% *}") ${ex##* } [$cls]"
done
api_ok && [ "$(api /connections | jq '[.connections[]? | select(.metadata.process|test("mihomo"))] | length')" -gt 0 ] &&
  tag WARN "bench traffic was seen by the main core: results are tunnelled, not direct"
tag INFO "speeds swing a lot over minutes; compare nodes in interleaved rounds before concluding which hop is slow"
