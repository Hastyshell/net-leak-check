#!/bin/bash
# Shared helpers for the net-leak-check scripts (source this file).
# macOS-first (Clash Verge Rev / mihomo); bash 3.2 compatible (stock /bin/bash).

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${NLC_OUT:-${TMPDIR:-/tmp}/net-leak-check}"
mkdir -p "$OUT" && chmod 700 "$OUT"
STATE="$OUT/state.env"            # raw values shared between scripts (never print this file)
[ -f "$STATE" ] || { : >"$STATE"; chmod 600 "$STATE"; }
MASK="${NLC_MASK:-1}"             # NLC_MASK=0 prints full IPs

tag() { printf '[%s] %s\n' "$1" "$2"; }   # PASS | WARN | FAIL | INFO | SKIP
section() { printf '\n== %s\n' "$1"; }

need() {
  local c missing=""
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || missing="$missing $c"; done
  [ -z "$missing" ] && return 0
  tag SKIP "missing required tools:$missing"
  return 1
}

state_set() {
  grep -v "^$1=" "$STATE" >"$STATE.tmp" 2>/dev/null
  printf '%s=%s\n' "$1" "$2" >>"$STATE.tmp"
  mv "$STATE.tmp" "$STATE" && chmod 600 "$STATE"
}
state_get() { sed -n "s/^$1=//p" "$STATE" | tail -1; }

mask_ip() {
  [ "$MASK" = 0 ] && { echo "$1"; return; }
  case $1 in
    *:*) echo "$1" | awk -F: '{print $1":"$2":…"}' ;;
    *.*.*.*) echo "$1" | awk -F. '{print $1"."$2".x.x"}' ;;
    *) echo "$1" ;;
  esac
}

# ---------- Clash Verge locations ----------
case "$(uname -s)" in
  Darwin) VERGE_DIR="$HOME/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev" ;;
  *) VERGE_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/io.github.clash-verge-rev.clash-verge-rev" ;;
esac
GEN_CFG="$VERGE_DIR/clash-verge.yaml"   # the config Verge generated and pushed to the core

# Top-level scalar from the generated config (no yq needed).
yaml_top() {
  [ -f "$GEN_CFG" ] || return 0
  awk -v k="$1" 'index($0, k ": ") == 1 { sub(/^[^:]+: */, ""); gsub(/["\047]/, ""); print; exit }' "$GEN_CFG"
}
# A whole top-level block (e.g. dns, sniffer, tun) from the generated config.
yaml_block() {
  [ -f "$GEN_CFG" ] || return 0
  awk -v k="$1:" '$0 == k { on = 1; print; next } on && /^[^ #-]/ { exit } on { print }' "$GEN_CFG"
}

# ---------- mihomo controller API (unix socket first, then TCP) ----------
_api_init() {
  [ -n "${API_MODE:-}" ] && return
  local s c secret
  for s in "/var/run/clash-verge-service/users/$(id -u)/verge-mihomo.sock" \
    "$(yaml_top external-controller-unix)" "${TMPDIR:-/tmp}/verge-mihomo.sock" /tmp/verge-mihomo.sock; do
    if [ -n "$s" ] && [ -S "$s" ] && curl -s -m 3 --unix-socket "$s" http://localhost/version | grep -q version; then
      API_MODE=unix API_SOCK=$s; return
    fi
  done
  secret=$(yaml_top secret)
  for c in "$(yaml_top external-controller)" 127.0.0.1:9097 127.0.0.1:9090; do
    [ -z "$c" ] && continue
    c=${c/0.0.0.0/127.0.0.1}
    if curl -s -m 3 -H "Authorization: Bearer $secret" "http://$c/version" | grep -q version; then
      API_MODE=tcp API_TCP=$c API_SECRET=$secret; return
    fi
  done
  API_MODE=none
}
api() {
  _api_init
  local p=$1; shift
  case $API_MODE in
    unix) curl -s -m 15 --unix-socket "$API_SOCK" "http://localhost$p" "$@" ;;
    tcp) curl -s -m 15 -H "Authorization: Bearer $API_SECRET" "http://$API_TCP$p" "$@" ;;
    *) return 1 ;;
  esac
}
api_ok() { _api_init; [ "$API_MODE" != none ]; }

mixed_port() {
  local p
  p=$(api /configs 2>/dev/null | jq -r '."mixed-port" // empty' 2>/dev/null)
  [ -n "$p" ] && [ "$p" != 0 ] && { echo "$p"; return; }
  p=$(yaml_top mixed-port)
  echo "${p:-7897}"
}
MIXED="${NLC_MIXED_PORT:-$(mixed_port)}"

tun_enabled() { [ "$(api /configs 2>/dev/null | jq -r '.tun.enable // false')" = true ]; }
tun_device() { api /configs 2>/dev/null | jq -r '.tun.device // empty'; }
# Address inside the TUN that Clash's DNS hijack answers on (first inet4-address of the tun).
tun_dns() {
  local a
  a=$(api /configs 2>/dev/null | jq -r '.tun["inet4-address"][0] // empty' | cut -d/ -f1)
  echo "${a:-198.18.0.1}"
}
phys_if() {
  local i
  i=$(scutil <<<"show State:/Network/Global/IPv4" 2>/dev/null | awk '/PrimaryInterface/ {print $3}')
  echo "${i:-en0}"
}

# fetch <tun|proxy> curl-args...   tun = whatever the OS does (TUN / other VPN / direct)
fetch() {
  local mode=$1; shift
  if [ "$mode" = proxy ]; then
    curl -s -m 12 -x "http://127.0.0.1:$MIXED" "$@"
  else
    curl -s -m 12 --noproxy '*' "$@"
  fi
}

# Unique live connections matching a jq filter, sampled for N seconds.
# Fields are separated by $US (0x1f): network host dstIP dstPort rule chain process.
# (Not tabs: `read` collapses consecutive whitespace separators and would drop empty fields.)
US=$'\037'
conn_snapshot() {
  local secs=$1 filt=$2 end tmp
  end=$(($(date +%s) + secs)); tmp=$(mktemp)
  while [ "$(date +%s)" -lt "$end" ]; do
    api /connections | jq -r ".connections[]? | select($filt) |
      [.metadata.network, (.metadata.host // \"\"), (.metadata.destinationIP // \"\"), (.metadata.destinationPort // \"\"),
       (.rule + (if (.rulePayload // \"\") != \"\" then \",\" + .rulePayload else \"\" end)),
       (.chains | reverse | join(\">\")), (.metadata.process // \"\")] | join(\"\u001f\")" >>"$tmp" 2>/dev/null
    sleep 0.3
  done
  sort -u "$tmp"; rm -f "$tmp"
}

# IPs of the proxy servers themselves (a VPS often sends UDP from its own address while TCP leaves
# via WARP or another egress). Resolved with Clash's resolver so fake-ip does not get in the way.
node_ips() {
  local cached s
  cached=$(state_get NODE_IPS)
  [ -n "$cached" ] && { echo "$cached"; return; }
  [ -f "$GEN_CFG" ] || return 0
  for s in $(awk '/^ *server: / {gsub(/["\047]/, "", $2); print $2}' "$GEN_CFG" | sort -u); do
    case $s in
      *[!0-9.]*) api "/dns/query?name=$s&type=A" 2>/dev/null | jq -r '.Answer[]? | select(.type==1) | .data' ;;
      *) echo "$s" ;;
    esac
  done | sort -u | tr '\n' ' ' | { read -r v; state_set NODE_IPS "${v:- }"; echo "$v"; }
}

# Classify an IP against exits recorded by exits.sh:
# HOME / PROXY / PROXY~(same /24) / NODE (a proxy server's own IP) / HOME~ / OTHER
classify_ip() {
  local ip=$1 home proxy p
  home=" $(state_get HOME_IPS) "; proxy=" $(state_get PROXY_IPS) "
  case "$home" in *" $ip "*) echo HOME; return ;; esac
  case "$proxy" in *" $ip "*) echo PROXY; return ;; esac
  case " $(node_ips) " in *" $ip "*) echo NODE; return ;; esac
  for p in $proxy; do
    case $ip in *.*.*.*) [ "${ip%.*}" = "${p%.*}" ] && { echo "PROXY~"; return; } ;; esac
  done
  for p in $home; do
    case $ip in *.*.*.*) [ "${ip%.*}" = "${p%.*}" ] && { echo "HOME~"; return; } ;; esac
  done
  echo OTHER
}

# "CC org" for an IP, looked up through the proxy (cached in state).
ip_org() {
  local key c
  key="ORG_$(echo "$1" | tr '.:' '__')"
  c=$(state_get "$key")
  [ -n "$c" ] && { echo "$c"; return; }
  # ip-api first (ipinfo rate-limits shared egresses such as WARP), ipinfo as fallback.
  c=$(curl -s -m 8 -x "http://127.0.0.1:$MIXED" "http://ip-api.com/json/$1?fields=status,countryCode,as" 2>/dev/null |
    jq -r 'select(.status=="success") | "\(.countryCode) \(.as)"' 2>/dev/null)
  [ -z "$c" ] && c=$(curl -s -m 8 -x "http://127.0.0.1:$MIXED" "https://ipinfo.io/$1/json" 2>/dev/null |
    jq -r 'select(.ip) | "\(.country // "?") \(.org // "?")"' 2>/dev/null)
  [ -z "$c" ] && c="? ?"
  state_set "$key" "$c"
  echo "$c"
}

# Portable timeout (macOS has no coreutils `timeout` by default).
with_timeout() { local s=$1; shift; perl -e 'alarm shift; exec @ARGV' "$s" "$@"; }
