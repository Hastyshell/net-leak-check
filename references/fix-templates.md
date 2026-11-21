# Fix templates (generic — fill the placeholders on the target machine)

Placeholders: `<PROXY_GROUP>` main proxy selector (e.g. `🚀 节点选择`), `<DIRECT_GROUP>` (e.g. `🎯 全球直连`
or `DIRECT`), `<CORP_DOMAINS>` company suffixes, `<CORP_RESOLVER>` the company VPN's local DNS proxy
(CorpLink: `127.0.0.1`), `<CORP_VIP_CIDR>` company virtual-IP range (CorpLink `central_dns.vip`).
Derive company values from the VPN's own config/logs on that machine; never commit them publicly.

Apply only with user approval, after backup + independent rollback, and verify with this skill.

## 1. DNS (profile `dns:` block or a Merge enhancement)

```yaml
dns:
  enable: true
  ipv6: false                     # Verge may force this from its IPv6 switch unless set via Merge
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  fake-ip-filter-mode: blacklist
  fake-ip-filter:
    - '+.lan'
    - '+.local'
    - '+.arpa'
    - '+.msftconnecttest.com'
    - '+.msftncsi.com'
    - time.*.com
    - ntp.*.com
    - '+.ntp.org'
    - time.apple.com
    - '+.ts.net'                  # Tailscale MagicDNS
    # - '+.<CORP_DOMAIN>'         # company names get real answers -> follow the VPN's routes
  default-nameserver: [223.5.5.5, 119.29.29.29]   # bootstrap only; upstreams below are IP literals
  nameserver:                     # everything not matched by a policy: overseas DoH THROUGH the proxy
    - 'https://1.1.1.1/dns-query#<PROXY_GROUP>'
    - 'https://8.8.8.8/dns-query#<PROXY_GROUP>'
  direct-nameserver:              # names whose connection ends up DIRECT -> in-China answers
    - https://223.5.5.5/dns-query
    - https://1.12.12.12/dns-query
  direct-nameserver-follow-policy: true
  proxy-server-nameserver:        # resolving the VPS hostname must not depend on the VPS
    - https://223.5.5.5/dns-query
    - https://1.12.12.12/dns-query
  nameserver-policy:
    # '+.<CORP_DOMAIN_1>,+.<CORP_DOMAIN_2>': <CORP_RESOLVER>
    '+.ts.net': 100.100.100.100
    '+.anthropic.com,+.claude.ai,+.claude.com,+.claudeusercontent.com,+.openai.com,+.chatgpt.com,+.oaistatic.com,+.oaiusercontent.com,+.gemini.google.com,+.generativelanguage.googleapis.com,+.aistudio.google.com,+.githubcopilot.com':
      - 'https://1.1.1.1/dns-query#<PROXY_GROUP>'
      - 'https://8.8.8.8/dns-query#<PROXY_GROUP>'
    '+.deepseek.com,+.doubao.com,+.volces.com,+.moonshot.cn,+.kimi.com,+.bigmodel.cn,+.qianwen.com,+.hunyuan.tencent.com,geosite:cn,geosite:private':
      - https://223.5.5.5/dns-query
      - https://1.12.12.12/dns-query
sniffer:
  enable: true
  force-dns-mapping: true
  parse-pure-ip: true
  override-destination: true
  sniff:
    HTTP: {ports: [80, 8080-8880]}
    TLS: {ports: [443, 8443]}
    QUIC: {ports: [443, 8443]}
  skip-domain: ['+.push.apple.com']
```

No `fallback`, no `system`/`dhcp` upstream — overseas names must never fall back to a CN resolver.

## 2. Rules to put first (Rules enhancement `prepend:` or top of `rules:`)

```yaml
- AND,((NETWORK,UDP),(DST-PORT,443)),REJECT     # QUIC: keeps one exit IP (VPS UDP vs WARP TCP)
# company VPN processes + names + virtual IPs stay off the proxy
- PROCESS-NAME,corplink-service,DIRECT
- PROCESS-NAME,CorpLink,DIRECT
# - DOMAIN-SUFFIX,<CORP_DOMAIN>,DIRECT
# - IP-CIDR,<CORP_VIP_CIDR>,DIRECT,no-resolve
# Tailscale
- PROCESS-NAME,tailscaled,DIRECT
- PROCESS-NAME,io.tailscale.ipn.macsys.network-extension,DIRECT
- PROCESS-NAME,IPNExtension,DIRECT
- DOMAIN-SUFFIX,ts.net,DIRECT
- IP-CIDR,100.64.0.0/10,DIRECT,no-resolve
- IP-CIDR6,fd7a:115c:a1e0::/48,DIRECT,no-resolve
# overseas AI -> VPS
- DOMAIN-SUFFIX,anthropic.com,<PROXY_GROUP>
- DOMAIN-SUFFIX,claude.ai,<PROXY_GROUP>
- DOMAIN-SUFFIX,claude.com,<PROXY_GROUP>
- DOMAIN-SUFFIX,openai.com,<PROXY_GROUP>
- DOMAIN-SUFFIX,chatgpt.com,<PROXY_GROUP>
- DOMAIN-SUFFIX,oaistatic.com,<PROXY_GROUP>
- DOMAIN-SUFFIX,oaiusercontent.com,<PROXY_GROUP>
- DOMAIN-SUFFIX,gemini.google.com,<PROXY_GROUP>
- DOMAIN-SUFFIX,generativelanguage.googleapis.com,<PROXY_GROUP>
- DOMAIN-SUFFIX,aistudio.google.com,<PROXY_GROUP>
- DOMAIN-SUFFIX,githubcopilot.com,<PROXY_GROUP>
# CN AI -> direct
- DOMAIN-SUFFIX,deepseek.com,DIRECT
- DOMAIN-SUFFIX,doubao.com,DIRECT
- DOMAIN-SUFFIX,moonshot.cn,DIRECT
- DOMAIN-SUFFIX,kimi.com,DIRECT
```

**GoogleCN direct rules** (ACL4SSR): list them from the live core and delete them when overseas DNS is in use:

```bash
api /rules | jq -r '.rules[] | select(.proxy|test("直连|DIRECT")) | select(.payload|test("gstatic\\.com|googleapis\\.com|google\\.com|pki\\.goog|recaptcha\\.net|googletag")) | "\(.type|ascii_upcase),\(.payload),\(.proxy)"'
```
(Rule type names in `/rules` are CamelCase — `DomainSuffix` → write `DOMAIN-SUFFIX` in Verge's `delete:` list; match the profile's exact strings.)

## 3. Nodes: enable UDP (Verge profile Script, or `udp: true` in the profile)

```js
function main(config) {
  if (Array.isArray(config.proxies)) config.proxies = config.proxies.map((p) => ({ ...p, udp: true }));
  return config;
}
```
Then confirm with `udp_check.sh` that STUN maps to PROXY/NODE, not HOME (some servers do not relay UDP).

## 4. TUN (Verge's own `config.yaml` → `tun:`; Verge overrides a profile's `tun`)

```yaml
tun:
  dns-hijack: [any:53, tcp://any:53]
  route-exclude-address: [100.64.0.0/10, fd7a:115c:a1e0::/48]   # Tailscale
  inet6-address: [fdfe:dcba:9876::1/126]                         # used only if the host has global IPv6
```

## 5. System proxy bypass (Verge `verge.yaml` → `system_proxy_bypass`, applied when sysproxy is enabled)

`*.<corp-domain>,*.local,*.ts.net,100.64.0.0/10,<CORP_VIP_CIDR>` (keep `use_default_bypass: true`).

## 6. Chrome WebRTC (system-proxy-only mode)

Write as root to `/Library/Managed Preferences/com.google.Chrome.plist` (root:wheel 644):
```xml
<dict><key>WebRtcIPHandling</key><string>disable_non_proxied_udp</string></dict>
```
Restart Chrome; verify with `browser_check.sh` (policy row "Mandatory / OK", no UDP candidates).
Trade-off: Chrome WebRTC calls use TCP relays only. Safari has no equivalent.

## 7. Company VPN with a catch-all resolver (CorpLink etc.)

Use `templates/clash-dns-guard/` (root LaunchDaemon). It publishes, only while Clash TUN is up and
answering DNS, a catch-all resolver → Clash that outranks the VPN's, plus the company domains →
the VPN's own resolver (read live from its State key). Withdraws within ~3 s otherwise. Kill switch:
`touch /Users/Shared/clash-dns-guard.disable`. Install/uninstall instructions in that folder.

## Rollback pattern

```bash
B=~/.clash-verge-backup-$(date +%Y%m%d-%H%M%S); mkdir -m 700 "$B"
tar -C "<verge dir>/.." -czf "$B/verge.tgz" "<verge dir name>"
# rollback.sh: wait until epoch in $B/deadline, unless $B/cancel exists; then restore the tgz,
# PUT the saved generated config to the core, restart Verge. Run it as a launchd *user agent*
# (RunAtLoad, KeepAlive false) so it survives the terminal/agent session. Cancel = touch $B/cancel.
```
