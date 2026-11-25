---
name: net-leak-check
description: Diagnose and (when requested) fix DNS, WebRTC, UDP, and IPv6 leaks and routing issues in a macOS Clash Verge Rev / mihomo proxy setup — verifying exit-IP consistency, overseas AI routing (Claude/OpenAI/ChatGPT/Codex/Gemini) via the user's VPS, domestic direct routing, local/LAN resolution, and coexistence with company VPNs (CorpLink/飞连 etc.) and Tailscale. Read-only by default; apply changes only when explicitly requested, with backup and independent auto-rollback.
---

# net-leak-check

Real measurements only. A green client icon, a config syntax check, or a generated template is never
evidence of deployment success. Every conclusion must come from a live probe in this skill (or an
equivalent live test).

## Ground rules

- **Response language:** Always respond and write reports in the **user's conversation language**
  (e.g. Chinese when the user writes in Chinese, English when in English), even though this skill and
  its reference checklists are written in English.
- **Inspect first, modify second (read-only by default):**
  - Never change any config, network setting, browser policy, or daemon unless the user explicitly asks
    to fix/apply changes.
  - Before making any changes: identify the OS, Clash Verge Rev / mihomo version, **currently active**
    effective config (never edit an unused file), system proxy, TUN, DNS, IPv6, and any other VPNs or
    tunnels; check for virtual NIC (`utun`), route, DNS, or CIDR conflicts with company VPNs.
  - Back up existing configs and arm an **independent** auto-rollback (surviving the current session,
    e.g. via `launchd`) before modifying anything; cancel the rollback only after live verification passes.
  - **Hard scope constraints:** Do not reinstall clients, do not modify the VPS, do not purchase extra
    services, do not delete existing user data, and do not disrupt company intranet or existing connections.
  - **Credentials & privileges:** When privileges or connection details are missing, ask only for what
    is strictly necessary. Passwords/secrets must be entered by the user through a secure prompt
    (never pasted in plain chat).
- **Do not open login pages** (e.g. Claude login) during troubleshooting. Probes use `cdn-cgi/trace`,
  unauthenticated API 401/404/302/200 responses, and `generate_204`.
- **Redact in reports:** Mask IPs by default (`a.b.x.x` when appropriate); never expose passwords,
  keys, UUIDs, tokens, subscription URLs, or credentials in the final report.
  `NLC_MASK=0` shows full IPs for your own local analysis only.
- **Honest reporting:** Explicitly label anything that could not be tested (no native IPv6 on the
  current network, Tailscale not running, company VPN disconnected, running Chrome window not yet
  restarted, etc.) as **untested** — never claim it passed.
- **Public repo hygiene:** Never commit company domains, internal CIDR ranges, or proxy node details
  to a public repository.

## Routing and DNS targets

When diagnosing or fixing a setup, evaluate against these five tiers (full task brief in
`references/acceptance-checklist.md`):

1. **Localhost & LAN:** `DIRECT`, resolved locally (via local DHCP DNS / mDNS / `/etc/hosts`; never
   leak `.lan`, `.local`, `.home.arpa`, or `geosite:private` to public CN or overseas DNS).
2. **Company intranet:** Preserve the company VPN's routes and internal DNS; never hijacked or
   misrouted by Clash.
3. **Domestic (CN) AI, CN websites, and CN CDNs:** `DIRECT`, resolved via direct domestic encrypted
   DNS (DoH).
4. **Overseas AI services (Claude, OpenAI, ChatGPT, Codex, Gemini, etc.):** Routed via the user's
   VPS, with DNS resolved via overseas DoH tunneled through the VPS.
5. **All other overseas and unmatched traffic:** Default via the user's VPS, with DNS also resolved
   via overseas DoH through the VPS.

### DNS & TUN invariants

- Overseas domains must **never** fall back to domestic DNS on resolution failure (no CN `fallback`).
- Audit **browser Secure DNS (DoH)**, **system DNS** (`scutil --dns` AND `/etc/resolv.conf`), and
  **Clash DNS** together for any bypass path.
- Configure `nameserver-policy` and rules in the **currently active** profile/merge config, verified
  against the live running core.
- When using `fake-ip`, keep `fake-ip-range` clear of company tunnels and existing routes, and exclude
  RFC1918 / company VPN / Tailscale CIDRs in `tun.route-exclude-address`.
- Confirm base proxy connectivity works before enabling TUN and DNS takeover to avoid cutting off
  network access.
- Keep UDP enabled (`udp: true`); verify TCP, UDP (STUN/WebRTC), and IPv6 separately.

## Run it

Scripts live in `scripts/` next to this file. Output goes to `${NLC_OUT:-$TMPDIR/net-leak-check}`.

```bash
S=<this skill dir>/scripts
bash $S/run_all.sh                       # inventory, exits, DNS, UDP/STUN, per-host rule/chain
bash $S/run_all.sh --with-browser        # + headless-Chrome policy and WebRTC candidates
bash $S/run_all.sh --with-page https://gemini.google.com/app   # + page render / icon fonts / "unusual traffic"
bash $S/run_all.sh --with-bench          # + per-node latency/throughput/exit (needs yq)
```

Individual probes (run `exits.sh` first — later scripts classify IPs against its HOME/PROXY results):

| script | what it proves |
|---|---|
| `inventory.sh` | OS, Verge/core versions, effective core config (`/configs`, `/proxies`, `/rules`), Clash DNS block, system DNS resolver order (by lowest `order` + `/etc/resolv.conf`), catch-all resolvers owned by other VPNs, pinned DNS routes, other utun routes, CorpLink split config, Tailscale, IPv6, Chrome policy files |
| `exits.sh` | HOME exit (CN sites, ≥2), PROXY exit (overseas sites via mixed port, ≥3), default-path (TUN) exits and AI endpoints classified as PROXY / HOME / OTHER, with country+ASN |
| `dnsleak.sh` | system resolver → fake-ip?; bash.ws resolver countries for real connections, proxy-port requests, plain lookups, and Clash DNS directly |
| `udp_check.sh` | STUN mapped address over the default path (WebRTC-equivalent), how Clash routed those UDP flows, nodes with `udp=false`, QUIC exit consistency |
| `route_check.sh [urls]` | the actual rule + chain the live core actually used per host, and HTTP outcome |
| `browser_check.sh` | throw-away headless Chrome: effective `chrome://policy` (WebRtcIPHandling, DoH, proxy) and ICE candidates with/without proxy |
| `browser_check.sh page URL [secs]` | icon-font status, failed requests by host, Google "unusual traffic" detection, screenshot |
| `bench.sh [nodes]` | per-node delay/speed/exit from a sandbox core **bound to the physical NIC** |
| `stun.py` | standalone STUN client (`--json`) |

Requirements: `curl`, `jq`, `python3` (stdlib only); optional `node` ≥ 22 (browser checks), `yq` (bench),
Google Chrome. macOS-first; most probes work wherever mihomo's controller is reachable.

## How to read results

Tags: `[FAIL]` leak/broken, `[WARN]` suspicious or degraded, `[PASS]` verified, `[INFO]` context, `[SKIP]` not run.
IP classes: `HOME` real home egress · `PROXY` same IP as the proxy-port exit (`PROXY~` same /24) ·
`NODE` a proxy server's own IP (normal for UDP when the VPS sends TCP via WARP) · `OTHER` another tunnel
(e.g. company VPN) — look at the ASN.

### Acceptance criteria (all must hold for "no leak, proxy works")

1. Overseas sites and AI endpoints (Claude, OpenAI, ChatGPT, Codex, Gemini) via TUN/default path = `PROXY`
   (or `NODE` for UDP); never `HOME`/`OTHER`. Never open Claude login.
2. ≥2 independent exit-IP sites agree with the VPS exit; AI `cdn-cgi/trace` (or API probe + live core
   logs) confirms proxy exit and DNS via VPS.
3. Overseas DNS upstream/path verified live (e.g. `bash.ws`, `browserleaks.com/dns`, `ipleak.net`,
   `o-o.myaddr.l.google.com TXT`, `whoami.ds.akahelp.net TXT`): **no China/ISP/company resolver** for
   overseas lookups, and failed overseas lookups never fall back to domestic DNS.
4. With TUN on, the system resolver (`mDNSResponder` lowest-`order` catch-all AND `/etc/resolv.conf`)
   routes to Clash (`fake-ip` returned for normal domains; local/LAN resolved locally; company domains
   routed to the company VPN resolver).
5. UDP STUN and browser WebRTC: overseas STUN mapped address is never `HOME` or company VPN — it exits
   via the VPS (`PROXY`/`NODE`); no UDP flow falls through to `DIRECT` with an empty rule.
6. Browser policies: Chrome `DnsOverHttpsMode=off` prevents DoH bypass; `WebRtcIPHandling` set to
   `default_public_interface_only` (TUN-only mode, preserving UDP STUN via VPS) or
   `disable_non_proxied_udp` (system-proxy-only mode where HTTP proxy cannot carry UDP).
7. CN sites & CN AI are `DIRECT` (`HOME` seen by CN IP-echo sites); company intranet websites, internal
   IPs, internal DNS, and SSH remain reachable via the company tunnel.
8. IPv6 checked for bypass (explicitly mark as untested if the current network has no global IPv6).
9. Re-run verification **after restarting Clash Verge Rev** to confirm settings persist.

Compare findings against `references/root-causes.md`. Deliver (in the user's conversation language):
**root causes → modified files & changes → live test results → untested/incomplete items → rollback method**.

## Pitfalls learned the hard way

- **macOS `IPMonitor` strips `SearchOrder` on supplemental-only DNS services.** Setting `SearchOrder # 1`
  on `State:/Network/Service/ClashDNSGuard/DNS` is silently deleted by `configd` (`ip_plugin.c` when no
  IPv4/IPv6 entity exists), causing priority to fall back to random `CFDictionary` iteration order and
  break after reboot. Always set **`SupplementalMatchOrders * # <int>`** (a `CFArray` of `CFNumber`
  matching the length of `SupplementalMatchDomains`), e.g. `40000+` for company domains, `45000+` for
  LAN domains, `50000` for Clash catch-all (deterministically outranking `102xxx` VPN resolvers).
- **`/var/run/resolv.conf` (`/etc/resolv.conf`) can still point at `127.0.0.1` even when `mDNSResponder`
  uses Clash.** `configd`'s `compareDomain()` leaves whichever catch-all service came first in
  `CFDictionary` order as `State:/Network/Global/DNS`. Sync `/var/run/resolv.conf` to `198.18.0.1` while
  `clash-dns-guard` is active (and restore on withdraw) so `dig`, `nslookup`, pure-Go, and c-ares tools
  do not leak to the company VPN's `127.0.0.1`.
- **`/Library/Managed Preferences/com.google.Chrome.plist` can be wiped by MDM on reboot** (e.g. CorpLink
  MDM). Writing to `/Library/Preferences/com.google.Chrome.plist` (`root:wheel`, mode `644`, followed by
  `killall cfprefsd`) persists across reboots and MDM refreshes and is loaded by Chrome (`chrome://policy`
  shows Recommended / OK). User-level `defaults write com.google.Chrome` alone is unreliable for policies.
- **Verify the live core, not files.** Compare `api /rules` count and first rules with what you expect;
  a rollback job or Verge regeneration can silently replace config. Check after every restart.
- **Cancel auto-rollback jobs as soon as verification passes**, or they will revert good fixes later.
- **Sandbox cores get re-captured by the main TUN.** Any test core must set `interface-name: <phys NIC>`
  (`bench.sh` does), otherwise every "node" is tunnelled through the currently selected one.
- **`curl --noproxy` through TUN is not a direct path**: TCP is terminated by mihomo; for real RTT/loss
  bind the socket to the NIC (`IP_BOUND_IF`, `ping -b en0`).
- **Throughput swings for minutes.** Compare paths in interleaved rounds and with concurrent runs
  (shared bottleneck ⇒ the sum stays at one path's speed) before naming the slow hop; rule out the home
  line with a direct CN CDN download.
- Chrome policy names change across versions (`WebRtcIPHandlingPolicy` → `WebRtcIPHandling`); always
  confirm via `chrome://policy` (`browser_check.sh`).
- zsh does not word-split `$VAR` holding several curl args; use arrays.
- macOS has no `timeout`; use `with_timeout` from `lib.sh`.

## Applying fixes (only when the user asks)

1. Confirm base proxy connectivity works before modifying TUN or DNS takeover.
2. Back up the Verge data dir (profiles, `verge.yaml`, `config.yaml`, generated config), any guard
   scripts/plists, Chrome policy plist, and baseline network state (`scutil --dns`, `scutil --proxy`,
   `netstat -rn`).
3. Arm an **independent** auto-rollback (`launchd` daemon/agent with a deadline epoch and cancel sentinel,
   not an in-session shell `sleep`).
4. Validate configs offline (`verge-mihomo -t -d <dir> -f <file>`), persist changes into the files
   Verge actually uses, and restart Clash Verge Rev.
5. Re-run verification (including after client restart); once all checks pass, cancel and unload the
   auto-rollback job while leaving a manual `restore.sh` script alongside the backup.

Generic, privacy-safe templates for the fixes that worked are in `references/fix-templates.md`
(DNS block, rules, UDP, QUIC, GoogleCN, TUN, system-proxy bypass, Chrome policy / nix-darwin, and
`references/templates/clash-dns-guard/` for coexisting with a company VPN's catch-all resolver).
The full task specification / acceptance checklist is in `references/acceptance-checklist.md`.
