# net-leak-check

A [Claude Code](https://docs.claude.com/en/docs/claude-code) skill (plus standalone scripts) that
diagnoses whether a macOS proxy setup built on **Clash Verge Rev / mihomo** leaks, and whether it
actually works — with live measurements, not config reading.

一个 Claude Code skill：实测诊断 Clash Verge Rev / mihomo 代理环境是否存在 DNS / WebRTC / UDP / IPv6
泄露、出口是否正确、AI 服务是否经代理、国内是否直连，以及与公司 VPN（如飞连 CorpLink）和 Tailscale 的冲突。

## What it checks

- **Exits** — real home egress vs. proxy egress (≥2 independent sites each), default path (TUN) vs. proxy port
- **DNS** — system resolver order, catch-all resolvers owned by other VPNs, fake-ip, resolver countries via bash.ws
- **UDP / WebRTC** — STUN mapped addresses, how mihomo routed UDP, nodes without UDP, QUIC exit consistency
- **Routing** — the rule and chain the live core actually used per host
- **Browser** — effective Chrome policies and ICE candidates in a throw-away headless profile; page render check
- **Nodes** — per-node latency / throughput / exit from a sandbox core bound to the physical NIC
- Reference material: symptom → root cause → evidence → fix table, generic fix templates

## Install

```bash
git clone https://github.com/Hastyshell/net-leak-check.git ~/.claude/skills/net-leak-check
```
Then ask Claude Code to "check my proxy for leaks", or run `/net-leak-check`. The scripts also work alone:

```bash
bash ~/.claude/skills/net-leak-check/scripts/run_all.sh --with-browser
```

Requirements: macOS, `curl`, `jq`, `python3`; optional Node ≥ 22 + Google Chrome (browser checks), `yq` (bench).

## Privacy and safety

- **Read-only.** Nothing is changed unless you explicitly ask Claude to apply a fix; fix templates require
  backups and an independent rollback first.
- **Third-party services contacted while running:** bash.ws (DNS leak test), ip-api.com and ipinfo.io
  (IP country/ASN, queried through your proxy), api.ipify.org, ifconfig.me, www.cloudflare.com and
  speed.cloudflare.com, myip.ipip.net, ip.3322.net, cip.cc, public STUN servers (Google, Cloudflare,
  Twilio, Nextcloud), and unauthenticated requests to AI / CN sites (claude.ai, chatgpt.com, api.openai.com,
  api.anthropic.com, gemini.google.com, baidu.com, …). No login pages are opened.
- **Reports stay local** (`$TMPDIR/net-leak-check`, mode 700). IPs are masked by default (`a.b.x.x`), but a
  report can still contain your proxy node / group names and, if you use a company VPN, company domain
  names. **Review a report before sharing it.**
- `bench.sh` writes a temporary copy of your generated config (containing node credentials) with mode 600
  into the output directory and deletes it on exit.
- Changing how company traffic is routed may violate your employer's policies. Check before applying fixes.

## Layout

```
SKILL.md                         instructions Claude follows (workflow, acceptance criteria, pitfalls)
scripts/                         run_all.sh, inventory.sh, exits.sh, dnsleak.sh, udp_check.sh,
                                 route_check.sh, browser_check.sh, bench.sh, stun.py, cdp.mjs, lib.sh
references/root-causes.md        symptom → cause → evidence → fix
references/fix-templates.md      generic DNS / rules / UDP / QUIC / TUN / Chrome templates
references/templates/clash-dns-guard/   root daemon for coexisting with a VPN's catch-all resolver
references/acceptance-checklist.md      end-to-end task specification & acceptance checklist (English; reports follow user's language)
```

## License

MIT — see [LICENSE](LICENSE).
