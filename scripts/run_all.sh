#!/bin/bash
# Full read-only diagnosis. Writes everything to $OUT/report-<time>.txt and prints a tag summary.
# Usage: run_all.sh [--with-browser] [--with-page URL] [--with-bench]
. "$(dirname "$0")/lib.sh"
D=$SCRIPTS_DIR
REPORT="$OUT/report-$(date +%Y%m%d-%H%M%S).txt"
: >"$STATE"; chmod 600 "$STATE"
BROWSER=0 PAGE="" BENCH=0
while [ $# -gt 0 ]; do
  case $1 in
    --with-browser) BROWSER=1 ;;
    --with-page) PAGE=${2:-https://gemini.google.com/app}; shift ;;
    --with-bench) BENCH=1 ;;
  esac
  shift
done
{
  echo "net-leak-check $(date '+%F %T')  (IPs masked: NLC_MASK=${MASK})"
  bash "$D/inventory.sh"
  bash "$D/exits.sh"
  bash "$D/dnsleak.sh"
  bash "$D/udp_check.sh"
  bash "$D/route_check.sh"
  [ $BROWSER = 1 ] && bash "$D/browser_check.sh"
  [ -n "$PAGE" ] && bash "$D/browser_check.sh" page "$PAGE" 30
  [ $BENCH = 1 ] && bash "$D/bench.sh"
} 2>&1 | tee "$REPORT"
chmod 600 "$REPORT"
echo
echo "================ SUMMARY ================"
for t in FAIL WARN PASS SKIP; do
  n=$(grep -c "^\[$t\]" "$REPORT")
  echo "$t: $n"
done
grep -E '^\[(FAIL|WARN)\]' "$REPORT"
echo "report: $REPORT"
