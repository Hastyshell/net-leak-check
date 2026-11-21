#!/bin/bash
# DNS leak check with bash.ws: unique subdomains are resolved in different ways, then bash.ws
# reports which recursive resolvers actually reached its authoritative server.
#  conn   : apps' real path — system resolver + an actual connection (fake-ip resolves remotely)
#  lookup : system resolver only (getaddrinfo), no connection
#  proxy  : HTTP through the Clash mixed port (Clash / the VPS resolves)
#  clash  : TXT straight to Clash DNS in the TUN (only when TUN is on)
# A China-located resolver for these overseas test names = overseas names leak to CN DNS.
. "$(dirname "$0")/lib.sh"
need curl jq python3 || exit 0

run() { # run <mode>
  local mode=$1 id i res
  id=$(curl -s -m 10 https://bash.ws/id)
  [ -z "$id" ] && { tag SKIP "bash.ws unreachable"; return; }
  for i in 1 2 3 4 5 6; do
    case $mode in
      conn) curl -s -m 5 --noproxy '*' -o /dev/null "http://$i.$id.bash.ws/" & ;;
      proxy) curl -s -m 5 -x "http://127.0.0.1:$MIXED" -o /dev/null "http://$i.$id.bash.ws/" & ;;
      lookup) python3 -I -c 'import socket,sys
try: socket.getaddrinfo(sys.argv[1], 80)
except OSError: pass' "$i.$id.bash.ws" & ;;
      clash) dig +short +time=3 +tries=1 @"$(tun_dns)" TXT "$i.$id.bash.ws" >/dev/null & ;;
    esac
  done
  wait; sleep 1
  res=$(curl -s -m 15 "https://bash.ws/dnsleak/test/$id?json" | jq -r '.[]? | select(type=="object" and .type=="dns") | "\(.country_name)\t\(.asn)"')
  if [ -z "$res" ]; then
    tag INFO "$mode: no resolver reached bash.ws (expected for 'lookup' with fake-ip: names are answered locally)"
    return
  fi
  echo "$res" | sort | uniq -c | while read -r n rest; do tag INFO "$mode: ${n}x $rest"; done
  if echo "$res" | grep -qiE '^China'; then
    case $mode in
      lookup) tag WARN "$mode: system lookups reach a China resolver — names you visit are visible to it (connections may still be proxied)" ;;
      *) tag FAIL "$mode: overseas names are resolved by a China resolver (DNS leak)" ;;
    esac
  else
    tag PASS "$mode: no China resolver"
  fi
}

section "Resolver chain"
first=$(scutil --dns | awk '/^resolver #1/ {on=1} on && /nameserver\[0\]/ {print $3; exit}')
tag INFO "system resolver #1: $first"
for d in www.google.com claude.ai api.openai.com www.baidu.com; do
  a=$(dscacheutil -q host -a name "$d" 2>/dev/null | awk '/ip_address/ {print $2; exit}')
  case $a in 198.18.* | 198.19.*) k="fake-ip (Clash)" ;; "") k="no answer" ;; *) k="real IP $(mask_ip "$a")" ;; esac
  tag INFO "system: $d -> $k"
done
if tun_enabled; then
  real=$(dscacheutil -q host -a name www.google.com | awk '/ip_address/ {print $2; exit}')
  case $real in
    198.18.* | 198.19.*) tag PASS "system DNS is answered by Clash (fake-ip)" ;;
    *) tag FAIL "TUN is on but the system resolver returns real IPs: DNS bypasses Clash (another catch-all resolver or a pinned DNS route)" ;;
  esac
fi
if api_ok; then
  g=$(api "/dns/query?name=www.google.com&type=A" | jq -r '[.Answer[]?.data] | join(" ")')
  tag INFO "Clash resolver answer for www.google.com: $(for x in $g; do mask_ip "$x"; done | tr '\n' ' ') (a non-Google ASN here means a polluted plaintext upstream)"
fi

section "bash.ws leak tests"
run conn
run proxy
run lookup
tun_enabled && run clash
tag INFO "bash.ws prints 'DNS may be leaking' whenever resolver ASN != exit ASN; judge by resolver country instead"
