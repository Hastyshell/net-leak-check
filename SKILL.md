---
name: net-leak-check
description: Diagnose whether this Mac's proxy setup (Clash Verge Rev / mihomo) leaks and whether it actually works — DNS leaks, WebRTC/UDP leaks, IPv6 bypass, exit-IP consistency, AI services (Claude/OpenAI/Gemini) routed via the user's VPS, CN sites direct, and coexistence with company VPNs (CorpLink/飞连 etc.) and Tailscale. Use when the user asks to check for leaks, verify the proxy/VPN, debug "only works with system proxy + TUN together", broken pages behind the proxy, or to repeat this diagnosis on another machine. Read-only by default; fixes only with explicit approval.
---

# net-leak-check

Real measurements only. A green client icon, a config that "looks right", or a generated template is
never evidence. Every conclusion must come from a probe in this skill (or an equivalent live test).

## Ground rules

- **Read-only by default.** Do not change any config, network setting, browser policy or daemon unless
  the user explicitly asks. If they do, follow "Applying fixes" below (backup + independent rollback).
- **Do not open login pages** (e.g. Claude login). Probes use `cdn-cgi/trace`, API 401/404s, `generate_204`.
- **Redact in reports:** IPs are masked by default (`a.b.x.x`); never print subscription URLs, node
  passwords/UUIDs, VPS hostnames, tokens, or company-internal hostnames in the final report.
  `NLC_MASK=0` shows full IPs for your own analysis only.
- Mark anything you could not exercise (no IPv6 on this network, Tailscale not installed, company VPN
  off, Chrome not installed…) as **untested**, never as passed.
- Never write to a public repo anything containing company domains, internal ranges or node details.

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
| `inventory.sh` | OS, Verge/core versions, effective core config (`/configs`, `/proxies`, `/rules`), Clash DNS block, system DNS resolver order, catch-all resolvers owned by other VPNs, pinned DNS routes, other utun routes, CorpLink split config, Tailscale, IPv6, Chrome policy files |
| `exits.sh` | HOME exit (CN sites, ≥2), PROXY exit (overseas sites via mixed port, ≥3), default-path (TUN) exits and AI endpoints classified as PROXY / HOME / OTHER, with country+ASN |
| `dnsleak.sh` | system resolver → fake-ip?; bash.ws resolver countries for real connections, proxy-port requests, plain lookups, and Clash DNS directly |
| `udp_check.sh` | STUN mapped address over the default path (WebRTC-equivalent), how Clash routed those UDP flows, nodes with `udp=false`, QUIC exit consistency |
| `route_check.sh [urls]` | the actual rule + chain the live core used per host, and HTTP outcome |
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

Acceptance (all must hold for "no leak, proxy works"):
1. Overseas sites and AI endpoints via TUN/default path = PROXY (or NODE for UDP); never HOME/OTHER.
2. ≥2 independent exit-IP sites agree; AI `cdn-cgi/trace` shows the proxy exit and a supported `loc`.
3. bash.ws shows **no China resolver** for `conn`, `proxy`, `clash` (a `lookup` China hit = names visible to a local resolver).
4. With TUN on, the system resolver returns fake-ip (resolver #1 is Clash).
5. STUN mapped address is never HOME; no UDP flow goes DIRECT with an empty rule.
6. Chrome: no srflx = HOME in either mode (system-proxy-only needs `WebRtcIPHandling=disable_non_proxied_udp`).
7. CN sites DIRECT (HOME seen by CN IP-echo sites); company intranet reachable via its own tunnel; SSH works.
8. Re-run after restarting the client: results unchanged (proves persistence).

Then compare against `references/root-causes.md` — it maps each symptom to the cause and the
evidence that confirmed it last time. Report: cause → evidence → files/settings involved → what is
untested → how to roll back (if anything was changed).

## Pitfalls learned the hard way

- **Verify the live core, not files.** Compare `api /rules` count and first rules with what you expect;
  a rollback job or Verge regeneration can silently replace config. Check after every restart.
- **Cancel auto-rollback jobs as soon as verification passes**, or they will revert good fixes later.
- **Sandbox cores get re-captured by the main TUN.** Any test core must set `interface-name: <phys NIC>`
  (bench.sh does), otherwise every "node" is tunnelled through the currently selected one.
- **`curl --noproxy` through TUN is not a direct path**: TCP is terminated by mihomo; for real RTT/loss
  bind the socket to the NIC (`IP_BOUND_IF`, `ping -b en0`).
- **Throughput swings for minutes.** Compare paths in interleaved rounds and with concurrent runs
  (shared bottleneck ⇒ the sum stays at one path's speed) before naming the slow hop; rule out the home
  line with a direct CN CDN download.
- Chrome policy names change across versions (`WebRtcIPHandlingPolicy` → `WebRtcIPHandling`); only
  `chrome://policy` showing "Mandatory / OK" counts. User-level `defaults write` is ignored on unmanaged Macs.
- zsh does not word-split `$VAR` holding several curl args; use arrays.
- macOS has no `timeout`; use `with_timeout` from `lib.sh`.

## Applying fixes (only when the user asks)

1. Back up the Verge data dir (profiles, verge.yaml, config.yaml, generated config) and network state.
2. Arm an **independent** auto-rollback (launchd user agent with a deadline file, not a shell sleep).
3. Validate configs offline (`verge-mihomo -t -d <dir> -f <file>`), try in a sandbox core, then live
   (`PUT /configs?force=true` payload), then persist into the files Verge actually uses and restart Verge.
4. Re-run this skill; compare semantically with the pre-change generated config; cancel the rollback.

Generic, privacy-safe templates for the fixes that worked are in `references/fix-templates.md`
(DNS block, rules, UDP, QUIC, GoogleCN, TUN, system-proxy bypass, Chrome policy, and
`references/templates/clash-dns-guard/` for coexisting with a company VPN's catch-all resolver).
The original task brief this skill came from is `references/acceptance-checklist.md`.
