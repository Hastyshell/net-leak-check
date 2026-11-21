#!/bin/bash
# Browser checks in a throw-away headless Chrome profile (the user's own Chrome is untouched):
#  - effective policies from chrome://policy (WebRtcIPHandling, DoH, proxy)
#  - WebRTC ICE candidates without a proxy (= TUN path) and with --proxy-server (= system-proxy browser)
#  - optional page render check: browser_check.sh page [url] [waitSeconds]
. "$(dirname "$0")/lib.sh"
need node python3 || exit 0
node -e 'process.exit(typeof WebSocket==="function"?0:1)' 2>/dev/null || { tag SKIP "Node >= 22 required (global WebSocket)"; exit 0; }
CH=$(ls -d "/Applications/Google Chrome.app" "$HOME/Applications/"*"/Google Chrome.app" "$HOME/Applications/Google Chrome.app" 2>/dev/null | head -1)
[ -z "$CH" ] && { tag SKIP "Google Chrome not found"; exit 0; }
BIN="$CH/Contents/MacOS/Google Chrome"
PROF="$OUT/chrome-profile"

start() { # start [extra chrome flags]
  rm -rf "$PROF"
  PORT=$(python3 -I -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')
  "$BIN" --headless=new --user-data-dir="$PROF" --no-first-run --hide-scrollbars --window-size=1280,800 \
    --remote-debugging-port="$PORT" "$@" about:blank >/dev/null 2>&1 &
  CPID=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do curl -s --noproxy "*" "http://127.0.0.1:$PORT/json/version" >/dev/null && return 0; sleep 0.5; done
  return 1
}
stop() { kill "$CPID" 2>/dev/null; wait "$CPID" 2>/dev/null; rm -rf "$PROF"; }
cdp() { (cd "$SCRIPTS_DIR" && with_timeout 120 node cdp.mjs "$PORT" "$@"); }

if [ "${1:-}" = page ]; then
  url=${2:-https://gemini.google.com/app}; wait_s=${3:-30}
  section "Page render: $url (wait ${wait_s}s)"
  start --lang=zh-CN || { tag FAIL "headless Chrome did not start"; exit 0; }
  shot="$OUT/page-$(date +%H%M%S).png"
  res=$(cdp page "$url" "$shot" $((wait_s * 1000)))
  stop
  echo "$res" | while read -r l; do tag INFO "$l"; done
  echo "$res" | grep -q GOOGLE_UNUSUAL_TRAFFIC && tag FAIL "Google 'unusual traffic' page (usually TCP and UDP/QUIC leaving from different IPs)"
  echo "$res" | grep -qE 'icon fonts:.*(error|loading)' && tag WARN "icon fonts not loaded (blocked font host, or very slow proxy)"
  tag INFO "screenshot: $shot (open it to see the rendered page)"
  exit 0
fi

section "Chrome effective policies"
start || { tag FAIL "headless Chrome did not start"; exit 0; }
pol=$(cdp policy); stop
if [ -n "$pol" ]; then echo "$pol" | while read -r l; do tag INFO "$l"; done; else tag INFO "could not read chrome://policy"; fi
echo "$pol" | grep -qE 'WebRtcIPHandling disable_non_proxied_udp' && tag PASS "WebRtcIPHandling=disable_non_proxied_udp is enforced"

section "WebRTC candidates"
for mode in tun proxy; do
  if [ $mode = proxy ]; then start --proxy-server="http://127.0.0.1:$MIXED"; else start; fi || { tag FAIL "headless Chrome did not start"; continue; }
  cands=$(cdp webrtc); stop
  label=$([ $mode = tun ] && echo "no proxy (TUN path)" || echo "system-proxy browser")
  if [ "$cands" = "(no candidates)" ]; then
    tag PASS "$label: no UDP candidates (UDP disabled by policy — no public IP exposed)"
    continue
  fi
  echo "$cands" | while read -r typ proto addr; do
    case $typ in
      host) case $addr in *.local) tag PASS "$label: host candidate hidden behind mDNS" ;; *) tag WARN "$label: raw local IP exposed $(mask_ip "$addr")" ;; esac ;;
      srflx | prflx)
        cls=$(classify_ip "$addr")
        case $cls in
          HOME*) tag FAIL "$label: public IP candidate = HOME $(mask_ip "$addr") (WebRTC leak)" ;;
          PROXY* | NODE) tag PASS "$label: public candidate = proxy side $(mask_ip "$addr")" ;;
          *) tag WARN "$label: public candidate $(mask_ip "$addr") [$cls] $(ip_org "$addr")" ;;
        esac ;;
      *) tag INFO "$label: $typ $proto $(mask_ip "$addr")" ;;
    esac
  done
done
tun_enabled && tag INFO "TUN is on, so the 'system-proxy browser' case still sends UDP into the TUN; without TUN it would go direct unless the policy disables non-proxied UDP"
