#!/bin/bash
# Exit-IP check. Records HOME (what CN sites see — expected DIRECT) and PROXY (what overseas sites
# see through the Clash mixed port), then classifies the default path (TUN / other VPN / direct)
# for overseas and AI endpoints. Uses >=2 independent sites per side.
. "$(dirname "$0")/lib.sh"
need curl jq || exit 0
IPRE='([0-9]{1,3}\.){3}[0-9]{1,3}'

cn_ips() {
  fetch "$1" https://myip.ipip.net | grep -oE "$IPRE" | head -1
  fetch "$1" https://ip.3322.net | grep -oE "$IPRE" | head -1
  fetch "$1" -A curl https://cip.cc | awk '/^IP/ {print $3; exit}'
}
os_ip() { # os_ip <mode> <site>
  case $2 in
    cf) fetch "$1" https://www.cloudflare.com/cdn-cgi/trace | sed -n 's/^ip=//p' ;;
    ipify) fetch "$1" https://api.ipify.org ;;
    ifconfig.me) fetch "$1" https://ifconfig.me/ip ;;
    ipinfo) fetch "$1" https://ipinfo.io/ip ;;
  esac
}
uniq_words() { tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' '; }
show() { # show <label> <ip>
  if [ -z "$2" ]; then tag WARN "$1: no answer"; return; fi
  printf '%s\n' "$2" | grep -qE "^$IPRE$|:" || { tag WARN "$1: unexpected answer"; return; }
  echo "$(classify_ip "$2")|$1|$(mask_ip "$2")|$(ip_org "$2")"
}

section "HOME exit (CN sites; expected DIRECT)"
home=$( (cn_ips proxy; cn_ips tun) | grep -E "^$IPRE$" | uniq_words)
[ -z "$home" ] && tag WARN "CN IP-echo sites unreachable; HOME unknown"
state_set HOME_IPS "$home"
for ip in $home; do tag INFO "HOME $(mask_ip "$ip") $(ip_org "$ip")"; done

section "PROXY exit (overseas sites via mixed port 127.0.0.1:$MIXED)"
proxy=""
for s in cf ipify ifconfig.me ipinfo; do
  ip=$(os_ip proxy $s); [ -n "$ip" ] && proxy="$proxy $ip"
  tag INFO "via proxy  $s -> $(mask_ip "${ip:-none}")"
done
proxy=$(echo "$proxy" | uniq_words)
state_set PROXY_IPS "$proxy"
if [ -z "$proxy" ]; then
  tag FAIL "overseas sites unreachable through the proxy port: proxy not working"
else
  for ip in $proxy; do
    case " $home " in *" $ip "*) tag FAIL "proxy exit equals HOME ($(mask_ip "$ip")): overseas traffic is not proxied" ;; esac
    tag INFO "PROXY $(mask_ip "$ip") $(ip_org "$ip")"
  done
  [ "$(echo "$proxy" | wc -w)" -gt 1 ] && tag INFO "several proxy exits (normal for WARP / load-balanced egress; check they share an ASN)"
fi

section "Default path (no explicit proxy: TUN, another VPN, or direct)"
tun_enabled && tag INFO "Clash TUN is ON (device $(tun_device))" || tag INFO "Clash TUN is OFF: only proxy-aware apps use Clash"
for s in cf ipify ifconfig.me ipinfo; do
  r=$(show "overseas $s" "$(os_ip tun $s)")
  case $r in \[*) echo "$r"; continue ;; esac
  cls=${r%%|*}
  case $cls in
    PROXY*) tag PASS "${r#*|}" ;;
    HOME*) if tun_enabled; then tag FAIL "${r#*|} — overseas traffic leaves with the real home IP"; else tag INFO "${r#*|} (expected without TUN)"; fi ;;
    *) tag WARN "${r#*|} — neither HOME nor PROXY: another tunnel (company VPN?) carries it" ;;
  esac
done

section "AI endpoints"
for h in claude.ai chatgpt.com; do
  for mode in tun proxy; do
    ip=$(fetch $mode "https://$h/cdn-cgi/trace" | sed -n 's/^ip=//p')
    loc=$(fetch $mode "https://$h/cdn-cgi/trace" | sed -n 's/^loc=//p')
    r=$(show "$h ($mode, loc=${loc:-?})" "$ip")
    case $r in \[*) echo "$r"; continue ;; esac
    cls=${r%%|*}
    case $cls in
      PROXY* | NODE) tag PASS "${r#*|}" ;;
      HOME*) if [ $mode = tun ] && ! tun_enabled; then tag INFO "${r#*|} (TUN off)"; else tag FAIL "${r#*|} — AI reached with the home IP"; fi ;;
      *) tag WARN "${r#*|} — not the proxy exit" ;;
    esac
  done
done
for u in https://api.openai.com/v1/models https://api.anthropic.com/v1/models https://gemini.google.com/ https://generativelanguage.googleapis.com/; do
  for mode in tun proxy; do
    tag INFO "$mode $(fetch $mode -o /dev/null -w '%{http_code} via %{remote_ip} %{time_total}s' "$u") ${u#https://}"
  done
done
tag INFO "via 198.18.x = fake-ip (Clash decides), via 127.0.0.1 = proxy port, any other IP = real address chosen outside Clash"

section "CN sites"
for u in https://www.baidu.com/ https://www.qq.com/ https://www.taobao.com/; do
  tag INFO "tun $(fetch tun -o /dev/null -w '%{http_code} %{time_total}s' "$u") ${u#https://}"
done
