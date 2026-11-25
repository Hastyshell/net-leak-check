#!/bin/bash
# Removes clash-dns-guard. Run with sudo.
launchctl bootout system/local.clash-dns-guard 2>/dev/null
for k in State:/Network/Service/ClashDNSGuard/DNS State:/Network/Service/ClashDNSGuardCorp/DNS State:/Network/Service/ClashDNSGuardLan/DNS; do
  printf 'remove %s\nquit\n' "$k" | scutil
done
rm -f /Library/LaunchDaemons/local.clash-dns-guard.plist
rm -rf /usr/local/clash-dns-guard
dscacheutil -flushcache; killall -HUP mDNSResponder 2>/dev/null
echo "clash-dns-guard removed"
