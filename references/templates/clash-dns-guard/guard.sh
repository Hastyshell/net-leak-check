#!/bin/bash
# clash-dns-guard — keeps macOS system DNS pointed at Clash while Clash TUN is up, so a company VPN's
# catch-all resolver (e.g. CorpLink's 127.0.0.1 that forwards to a pinned plaintext upstream) cannot
# bypass Clash's TUN DNS hijack. Company domains keep going to the VPN's own resolver.
#
# While an utun carries $CLASH_DNS and Clash answers DNS there, publish:
#   - State:/Network/Service/ClashDNSGuard/DNS      catch-all -> $CLASH_DNS (SearchOrder 1)
#   - State:/Network/Service/ClashDNSGuardCorp/DNS  company domains -> the VPN resolver (only while the VPN key exists)
# Otherwise (TUN off, Clash not answering, kill switch) both are withdrawn.
# Config: /usr/local/clash-dns-guard/corp-domains.txt (one suffix per line, optional)
CLASH_DNS=${CLASH_DNS:-198.18.0.1}
VPN_KEY=${VPN_KEY:-State:/Network/Service/CorplinkDNSProxy/DNS}   # the VPN's catch-all resolver key
KILL=/Users/Shared/clash-dns-guard.disable
KEY=State:/Network/Service/ClashDNSGuard/DNS
CORP_KEY=State:/Network/Service/ClashDNSGuardCorp/DNS
DOMAINS_FILE=/usr/local/clash-dns-guard/corp-domains.txt

log() { echo "$(date '+%F %T') $*"; }
key_exists() { [[ $(printf 'show %s\nquit\n' "$1" | scutil) != *"No such key"* ]]; }
flush() { dscacheutil -flushcache; killall -HUP mDNSResponder 2>/dev/null; }
vpn_resolver() { printf 'show %s\nquit\n' "$VPN_KEY" | scutil | awk '/ServerAddresses/ {on=1; next} on && /0 :/ {print $3; exit}'; }

publish_main() {
  scutil <<EOF
d.init
d.add ServerAddresses * $CLASH_DNS
d.add SupplementalMatchDomains * ""
d.add SearchOrder # 1
d.add SupplementalMatchDomainsNoSearch # 1
set $KEY
EOF
}

publish_corp() {
  local domains
  domains=$(grep -vE '^\s*(#|$)' "$DOMAINS_FILE" 2>/dev/null | tr '\n' ' ')
  [[ -z $domains ]] && return 1
  scutil <<EOF
d.init
d.add ServerAddresses * $1
d.add SupplementalMatchDomains * $domains
d.add SearchOrder # 1
d.add SupplementalMatchDomainsNoSearch # 1
set $CORP_KEY
EOF
}

withdraw() {
  local changed=0
  key_exists $KEY && { printf 'remove %s\nquit\n' $KEY | scutil; changed=1; }
  key_exists $CORP_KEY && { printf 'remove %s\nquit\n' $CORP_KEY | scutil; changed=1; }
  ((changed)) && { flush; log "withdrawn ($1)"; }
}

trap 'withdraw "guard stopping"; exit 0' TERM INT HUP
log "guard started"
while true; do
  if [[ -e $KILL ]]; then
    withdraw "kill switch"
  elif ifconfig | grep -q "inet $CLASH_DNS " &&
    dig +time=1 +tries=2 +short @$CLASH_DNS clash-dns-guard.health.example A | grep -q .; then
    changed=0
    if ! key_exists $KEY; then publish_main; changed=1; log "published catch-all -> $CLASH_DNS"; fi
    if key_exists "$VPN_KEY"; then
      if ! key_exists $CORP_KEY; then
        r=$(vpn_resolver)
        [[ -n $r ]] && publish_corp "$r" && { changed=1; log "published company domains -> $r"; }
      fi
    elif key_exists $CORP_KEY; then
      printf 'remove %s\nquit\n' $CORP_KEY | scutil; changed=1; log "VPN gone, company resolver withdrawn"
    fi
    ((changed)) && flush
  else
    withdraw "Clash TUN/DNS not available"
  fi
  sleep 3
done
