#!/bin/bash
# UDP / WebRTC-style leak check: STUN binding requests over the default path, the mapped address
# classified against HOME / PROXY (from exits.sh), plus how Clash routed those UDP flows.
. "$(dirname "$0")/lib.sh"
need python3 jq || exit 0
[ -z "$(state_get PROXY_IPS)" ] && tag INFO "run exits.sh first for HOME/PROXY classification"

section "STUN over the default path"
tmp=$(mktemp)
python3 -I "$SCRIPTS_DIR/stun.py" --json >"$tmp" &
pid=$!
snap=""
api_ok && snap=$(conn_snapshot 4 '.metadata.network=="udp" and (.metadata.destinationPort|test("^(3478|19302|443)$"))')
wait $pid
udp_exit=""
for row in $(jq -r '.[] | [.server, (.dst // "-"), (.mapped // "-"), (.note|gsub(" ";"_"))] | join("|")' "$tmp"); do
  IFS='|' read -r srv dst mapped note <<<"$row"
  if [ "$mapped" = - ]; then
    tag INFO "$srv: ${note//_/ }"
    continue
  fi
  cls=$(classify_ip "$mapped")
  line="$srv -> mapped $(mask_ip "$mapped") [$cls] $(ip_org "$mapped") (dst $(mask_ip "$dst"))"
  case $cls in
    HOME*) tag FAIL "$line — UDP leaves with the real home IP (WebRTC leak)" ;;
    PROXY*) tag PASS "$line" ; udp_exit="$udp_exit $mapped" ;;
    NODE) tag PASS "$line — the proxy server's own IP (native UDP egress; TCP may leave via WARP)" ; udp_exit="$udp_exit $mapped" ;;
    *) tag WARN "$line — not the TCP proxy exit (VPS native UDP egress, or another tunnel). Check the org above" ; udp_exit="$udp_exit $mapped" ;;
  esac
done
rm -f "$tmp"

section "How Clash routed the UDP flows"
if [ -n "$snap" ]; then
  echo "$snap" | while IFS="$US" read -r net host dip dport rule chain proc; do
    tag INFO "udp ${host:-$(mask_ip "$dip")}:$dport rule=${rule:-<none>} chain=$chain"
    [ -z "$rule" ] && [ "$chain" = DIRECT ] &&
      tag FAIL "UDP went DIRECT with no matching rule: the matched proxy has no UDP support, mihomo fell through to DIRECT"
  done
else
  tag INFO "no UDP flows seen in Clash (TUN off, or traffic carried by another tunnel)"
fi
if api_ok; then
  bad=$(api /proxies | jq -r '.proxies | to_entries[] | select(.value.type|test("^(Vmess|Vless|Trojan|Shadowsocks|ShadowsocksR|Snell|AnyTLS|Http|Socks5)$")) | select(.value.udp==false) | .key' | tr '\n' ' ')
  [ -n "$bad" ] && tag WARN "nodes with udp=false: $bad" || tag PASS "all proxy nodes support UDP"
fi

section "QUIC exit consistency"
if api_ok; then
  if api /rules | jq -e '.rules[] | select(.type=="AND" and (.payload|test("udp";"i")) and (.payload|test("443")) and .proxy=="REJECT")' >/dev/null; then
    tag PASS "QUIC (UDP 443) rejected: browsers use TCP, single exit IP"
  else
    mism=""
    for u in $udp_exit; do case $(classify_ip "$u") in PROXY) ;; *) mism=1 ;; esac; done
    [ -n "$mism" ] && tag WARN "UDP exit differs from TCP exit and QUIC is not rejected: Google may flag 'unusual traffic' (IP a ≠ IP b) and break pages" ||
      tag INFO "QUIC allowed; UDP and TCP exits look consistent"
  fi
fi
