#!/bin/bash
# clash-dns-guard — keeps macOS system DNS pointed at Clash while Clash TUN is up, so a company VPN's
# catch-all resolver (e.g. CorpLink's 127.0.0.1 that forwards to a pinned plaintext upstream) cannot
# bypass Clash's TUN DNS hijack. Company domains keep going to the VPN's own resolver, and LAN domains
# resolve locally via the primary interface's DHCP DNS.
#
# Why SupplementalMatchOrders (not SearchOrder):
#   macOS configd IPMonitor strips SearchOrder from supplemental-only DNS services (no IPv4/IPv6 entity),
#   causing priority to fall back to random CFDictionary iteration order across boots.
#   SupplementalMatchOrders (CFArray of CFNumber) is preserved by IPMonitor and sets deterministic order:
#     40000+ : ClashDNSGuardCorp -> VPN resolver (only while $VPN_KEY exists)
#     45000+ : ClashDNSGuardLan  -> primary interface private DHCP DNS (dynamic)
#     50000  : ClashDNSGuard     -> $CLASH_DNS (catch-all, outranking 102xxx VPN catch-all)
#
# Additionally syncs /var/run/resolv.conf (/etc/resolv.conf) -> $CLASH_DNS while active (and restores
# on withdraw) so CLI tools reading /etc/resolv.conf (dig, nslookup, pure-Go, c-ares) do not leak.
#
# Config: /usr/local/clash-dns-guard/corp-domains.txt (one suffix per line, optional)
# Kill switch: /Users/Shared/clash-dns-guard.disable
CLASH_DNS=${CLASH_DNS:-198.18.0.1}
VPN_KEY=${VPN_KEY:-State:/Network/Service/CorplinkDNSProxy/DNS}   # the VPN's catch-all resolver key
KILL=${KILL:-/Users/Shared/clash-dns-guard.disable}
KEY=State:/Network/Service/ClashDNSGuard/DNS
CORP_KEY=State:/Network/Service/ClashDNSGuardCorp/DNS
LAN_KEY=State:/Network/Service/ClashDNSGuardLan/DNS
RESOLV_CONF=/var/run/resolv.conf
DOMAINS_FILE=/usr/local/clash-dns-guard/corp-domains.txt
BASE_LAN_DOMAINS=(lan home.arpa my.router)

LAST_LAN_SIG=""

log() { echo "$(date '+%F %T') $*"; }
key_exists() { [[ $(printf 'show %s\nquit\n' "$1" | scutil) != *"No such key"* ]]; }
key_has_orders() { [[ $(printf 'show %s\nquit\n' "$1" | scutil) == *"SupplementalMatchOrders"* ]]; }
flush() { dscacheutil -flushcache; killall -HUP mDNSResponder 2>/dev/null; }
vpn_resolver() { printf 'show %s\nquit\n' "$VPN_KEY" | scutil | awk '/ServerAddresses/ {on=1; next} on && /0 :/ {print $3; exit}'; }

is_private_ip() {
  case "$1" in
    10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[0-1].*) return 0 ;;
    *) return 1 ;;
  esac
}

get_primary_dhcp_dns() {
  local psvc dns_info ip dom
  psvc=$(printf 'show State:/Network/Global/IPv4\nquit\n' | scutil | awk '/PrimaryService/{print $3; exit}')
  [[ -z "$psvc" ]] && return 1
  dns_info=$(printf 'show State:/Network/Service/%s/DNS\nquit\n' "$psvc" | scutil)
  ip=$(printf '%s\n' "$dns_info" | awk '/ServerAddresses/{in_arr=1; next} in_arr && /}/{exit} in_arr && /^[[:space:]]*[0-9]+ :/{print $3; exit}')
  dom=$(printf '%s\n' "$dns_info" | awk '/DomainName :/{print $3; exit}')
  if [[ -n "$ip" ]] && is_private_ip "$ip"; then
    printf '%s|%s\n' "$ip" "$dom"
    return 0
  fi
  return 1
}

sync_resolv_conf() {
  local cur search_line
  cur=$(awk '/^nameserver /{print $2; exit}' "$RESOLV_CONF" 2>/dev/null)
  if [[ "$cur" != "$CLASH_DNS" ]]; then
    search_line=$(grep '^search ' "$RESOLV_CONF" 2>/dev/null | head -n 1)
    {
      echo "# Managed by clash-dns-guard while Clash TUN is active"
      [[ -n "$search_line" ]] && echo "$search_line"
      echo "nameserver $CLASH_DNS"
    } > "${RESOLV_CONF}.clashguard.tmp" && chmod 644 "${RESOLV_CONF}.clashguard.tmp" && mv -f "${RESOLV_CONF}.clashguard.tmp" "$RESOLV_CONF"
    log "synced $RESOLV_CONF -> $CLASH_DNS (was: ${cur:-empty})"
  fi
}

restore_resolv_conf() {
  local gns search_line
  gns=$(printf 'show State:/Network/Global/DNS\nquit\n' | scutil | awk '/ServerAddresses/{in_arr=1; next} in_arr && /}/{exit} in_arr && /^[[:space:]]*[0-9]+ :/{print $3; exit}')
  if [[ -n "$gns" && "$gns" != "$CLASH_DNS" ]]; then
    search_line=$(grep '^search ' "$RESOLV_CONF" 2>/dev/null | head -n 1)
    {
      echo "# Restored by clash-dns-guard"
      [[ -n "$search_line" ]] && echo "$search_line"
      echo "nameserver $gns"
    } > "${RESOLV_CONF}.clashguard.tmp" && chmod 644 "${RESOLV_CONF}.clashguard.tmp" && mv -f "${RESOLV_CONF}.clashguard.tmp" "$RESOLV_CONF"
    log "restored $RESOLV_CONF -> $gns"
  fi
}

publish_main() {
  scutil <<EOF
d.init
d.add ServerAddresses * $CLASH_DNS
d.add SupplementalMatchDomains * ""
d.add SupplementalMatchOrders * # 50000
d.add SupplementalMatchDomainsNoSearch # 1
set $KEY
EOF
}

publish_corp() {
  local domains=() orders=() o=40000 line
  while IFS= read -r line; do
    domains+=("$line")
    orders+=("$o")
    ((o++))
  done < <(grep -vE '^\s*(#|$)' "$DOMAINS_FILE" 2>/dev/null)
  (( ${#domains[@]} == 0 )) && return 1
  scutil <<EOF
d.init
d.add ServerAddresses * $1
d.add SupplementalMatchDomains * ${domains[*]}
d.add SupplementalMatchOrders * # ${orders[*]}
d.add SupplementalMatchDomainsNoSearch # 1
set $CORP_KEY
EOF
}

publish_lan() {
  local lan_ip="$1" extra_dom="$2"
  local domains=("${BASE_LAN_DOMAINS[@]}") orders=() o=45000 found=0 d
  if [[ -n "$extra_dom" ]]; then
    for d in "${domains[@]}"; do [[ "$d" == "$extra_dom" ]] && found=1; done
    (( ! found )) && domains+=("$extra_dom")
  fi
  for d in "${domains[@]}"; do orders+=("$o"); ((o++)); done
  scutil <<EOF
d.init
d.add ServerAddresses * $lan_ip
d.add SupplementalMatchDomains * ${domains[*]}
d.add SupplementalMatchOrders * # ${orders[*]}
d.add SupplementalMatchDomainsNoSearch # 1
set $LAN_KEY
EOF
}

withdraw() {
  local changed=0
  key_exists "$KEY" && { printf 'remove %s\nquit\n' "$KEY" | scutil; changed=1; }
  key_exists "$CORP_KEY" && { printf 'remove %s\nquit\n' "$CORP_KEY" | scutil; changed=1; }
  key_exists "$LAN_KEY" && { printf 'remove %s\nquit\n' "$LAN_KEY" | scutil; changed=1; }
  LAST_LAN_SIG=""
  if ((changed)); then
    restore_resolv_conf
    flush
    log "withdrawn ($1)"
  fi
}

trap 'withdraw "guard stopping"; exit 0' TERM INT HUP
log "guard started"
while true; do
  if [[ -e $KILL ]]; then
    withdraw "kill switch"
  elif ifconfig | grep -q "inet $CLASH_DNS " &&
    dig +time=1 +tries=2 +short @$CLASH_DNS clash-dns-guard.health.example A | grep -q .; then
    changed=0
    if ! key_exists "$KEY" || ! key_has_orders "$KEY"; then
      publish_main; changed=1; log "published catch-all -> $CLASH_DNS (order 50000)"
    fi
    if key_exists "$VPN_KEY"; then
      if ! key_exists "$CORP_KEY" || ! key_has_orders "$CORP_KEY"; then
        r=$(vpn_resolver)
        [[ -n $r ]] && publish_corp "$r" && { changed=1; log "published company domains -> $r (order 40000+)"; }
      fi
    elif key_exists "$CORP_KEY"; then
      printf 'remove %s\nquit\n' "$CORP_KEY" | scutil; changed=1; log "VPN gone, company resolver withdrawn"
    fi
    lan_info=$(get_primary_dhcp_dns)
    if [[ -n "$lan_info" ]]; then
      if [[ "$lan_info" != "$LAST_LAN_SIG" ]] || ! key_exists "$LAN_KEY" || ! key_has_orders "$LAN_KEY"; then
        publish_lan "${lan_info%%|*}" "${lan_info#*|}"
        LAST_LAN_SIG="$lan_info"
        changed=1
        log "published LAN domains -> ${lan_info%%|*} (order 45000+)"
      fi
    elif key_exists "$LAN_KEY"; then
      printf 'remove %s\nquit\n' "$LAN_KEY" | scutil; LAST_LAN_SIG=""; changed=1; log "LAN DHCP DNS unavailable, LAN resolver withdrawn"
    fi
    sync_resolv_conf
    ((changed)) && flush
  else
    withdraw "Clash TUN/DNS not available"
  fi
  sleep 3
done
