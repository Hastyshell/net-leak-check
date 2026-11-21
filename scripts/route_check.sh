#!/bin/bash
# Which rule / chain Clash actually used for given hosts (default path), plus HTTP result.
# Usage: route_check.sh [url ...]   (default: AI, Google static assets, CN sites)
. "$(dirname "$0")/lib.sh"
need curl jq || exit 0
api_ok || { tag SKIP "controller not reachable"; exit 0; }
URLS=${*:-"https://claude.ai/cdn-cgi/trace https://api.anthropic.com/ https://chatgpt.com/cdn-cgi/trace https://api.openai.com/ https://gemini.google.com/ https://fonts.gstatic.com/ https://www.gstatic.com/ https://fonts.googleapis.com/ https://github.com/ https://www.baidu.com/ https://www.bilibili.com/ https://chat.deepseek.com/"}

section "Rule / chain per host (live connections)"
hosts=""
tmp=$(mktemp)
for u in $URLS; do
  h=${u#*://}; h=${h%%/*}; hosts="$hosts|$h"
  (curl -s -m 12 --noproxy '*' -o /dev/null -w "%{http_code} %{time_total}s via %{remote_ip}\t$h\n" "$u" >>"$tmp") &
done
re="^(${hosts#|})$"
snap=$(conn_snapshot 4 ".metadata.network==\"tcp\" and ((.metadata.host // \"\")|test(\"$re\"))")
wait
echo "$snap" | cut -d"$US" -f2,5,6 | sort -u | while IFS="$US" read -r host rule chain; do
  [ -n "$host" ] && tag INFO "$host  rule=$rule  chain=$chain"
done
seen=$(echo "$snap" | cut -d"$US" -f2 | sort -u | tr '\n' ' ')
for u in $URLS; do
  h=${u#*://}; h=${h%%/*}
  case " $seen " in *" $h "*) ;; *) tag INFO "$h: connection too short to sample, or did not pass through Clash (other tunnel / IP route)" ;; esac
done
section "HTTP results (default path)"
sort -t$'\t' -k2 "$tmp" | while IFS=$'\t' read -r r h; do
  case $r in 000*) tag WARN "$h: $r (failed)" ;; *) tag INFO "$h: $r" ;; esac
done
rm -f "$tmp"
tag INFO "a Google static host on a DIRECT chain that fails/times out = GoogleCN direct rule + overseas DNS"
