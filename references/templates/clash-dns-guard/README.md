# clash-dns-guard (template)

Needed only when another app (company VPN) owns a catch-all system resolver that outranks Clash —
`inventory.sh` reports it as `[FAIL] a catch-all resolver (...) outranks Clash`. Without such a VPN,
Verge's own TUN DNS handling is enough.

## Install (root; ask the user for the password via a secure prompt)

```bash
T=<skill dir>/references/templates/clash-dns-guard
sudo mkdir -p /usr/local/clash-dns-guard
sudo install -o root -g wheel -m 755 "$T/guard.sh" "$T/uninstall.sh" /usr/local/clash-dns-guard/
# company suffixes, one per line (derive from the VPN's split-DNS config; keep private):
sudo tee /usr/local/clash-dns-guard/corp-domains.txt >/dev/null <<'EOF'
# example.corp
EOF
sudo install -o root -g wheel -m 644 "$T/local.clash-dns-guard.plist" /Library/LaunchDaemons/
sudo launchctl bootstrap system /Library/LaunchDaemons/local.clash-dns-guard.plist
```

Set `VPN_KEY` (EnvironmentVariables in the plist) if the VPN's resolver key is not
`State:/Network/Service/CorplinkDNSProxy/DNS` — find it with `inventory.sh` ("catch-all supplemental resolver").

## Verify

`scutil --dns` → resolver #1 = 198.18.0.1, company domains → the VPN resolver, no search domains added;
`dnsleak.sh` → system DNS answered by Clash; intranet hosts still resolve to internal IPs and work.
Fail-safe test: `touch /Users/Shared/clash-dns-guard.disable` → within ~3 s resolver #1 is the VPN again;
remove the file → back to Clash. Log: `/usr/local/clash-dns-guard/guard.log`.

## Remove

`sudo /usr/local/clash-dns-guard/uninstall.sh`
