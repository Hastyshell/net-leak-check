# Task Specification & Acceptance Checklist

This skill is grounded in the following end-to-end diagnostic, remediation, and verification
requirements. When reusing this skill on another machine, both diagnosis and remediation must satisfy
this checklist. Always deliver final reports and user-facing explanations in the **user's conversation
language**.

## I. Inspect First, Modify Second

- Identify the host OS, Clash Verge Rev / mihomo version, **currently active** effective configuration,
  system proxy, TUN, DNS, IPv6, and any other VPNs or tunnels.
- Check whether Clash and a company VPN have virtual NIC (`utun`), routing, DNS, or CIDR conflicts.
- Back up existing configurations first and arm an **auto-rollback running independently of the current
  session** (e.g. a `launchd` job); cancel the rollback only after live connectivity and leak checks pass.
- Do **not** reinstall clients, do **not** modify the VPS, do **not** purchase extra services, do **not**
  delete existing data, and do **not** disrupt company intranet access or existing connections.
- When permissions or connection details are missing, ask only for the minimal necessary information;
  passwords must be entered by the user via a secure prompt, never in plain chat.

## II. Routing & DNS Targets

1. **Localhost & LAN:** `DIRECT`, using local resolution (DHCP LAN DNS / mDNS / `/etc/hosts`).
2. **Company intranet:** Preserve the company VPN's routes and internal DNS; never hijacked or misrouted
   by Clash.
3. **Domestic (CN) AI, CN websites, and CN CDNs:** `DIRECT`, using direct domestic encrypted DNS (DoH).
4. **Overseas AI services (Claude, OpenAI, ChatGPT, Codex, Gemini, etc.):** Routed via the user's VPS,
   with DNS using overseas DoH accessed through the VPS.
5. **Other overseas and unmatched traffic:** Default via the user's VPS, with DNS likewise via the VPS.

## III. DNS & TUN

- Overseas domains must **never** fall back to domestic DNS on resolution failure.
- Check for any bypass across browser Secure DNS (DoH), system DNS (`scutil --dns` and
  `/etc/resolv.conf`), and Clash DNS.
- Configure `nameserver-policy` and routing rules in the **currently active** effective config — never
  modify only an unused config file.
- When using `fake-ip`, ensure `fake-ip-range` avoids company tunnels and existing routes (and exclude
  private/company/Tailscale ranges from TUN routes).
- Confirm base proxy connectivity works before enabling TUN and DNS takeover to avoid cutting off the
  network.
- Keep UDP enabled; verify that TCP, UDP, and IPv6 are routed as expected.

## IV. Live Acceptance Verification

- Verify overseas exit IP matches the VPS exit using **at least two independent check sites** (`exits.sh`,
  browser checks).
- Verify the **actual DNS upstream and resolution path** for overseas test domains — never rely on
  reading config text alone (`dnsleak.sh`, `route_check.sh`, `browserleaks.com/dns`, `ipleak.net`).
- Verify overseas AI domains route both connections and DNS through the VPS; **do not open Claude login**
  during troubleshooting (`exits.sh`, `route_check.sh`, live core logs).
- Spot-check domestic websites & domestic AI for direct routing, and verify company intranet websites,
  internal IPs, internal DNS, and SSH remain accessible (`exits.sh` + targeted intranet/SSH probes).
- Independently test **UDP and browser WebRTC**; overseas STUN must not expose the local public ISP IP
  (or company VPN IP) and must exit via the VPS as expected (`udp_check.sh`, `browser_check.sh`,
  `browserleaks.com/webrtc`, `ipleak.net`).
- Check whether **IPv6 bypasses the proxy** (`inventory.sh`, `curl -6`, browser IPv6 test; mark as
  untested if the current network has no global IPv6).
- **Restart the Clash client and verify again** to confirm all changes persist across restarts.
- Never treat a green client indicator, a config syntax check, or a generated template as successful
  deployment.

## V. Deliverable Requirements

- Report (in the user's conversation language): actual root cause(s), modified files and exact changes,
  live test results, incomplete/untested items, and rollback instructions.
- Sanitize the report: never expose passwords, keys, UUIDs, tokens, or subscription credentials.
- Explicitly mark any item that could not be tested live; never claim it passed verification.

## Common Additional Real-World Requirements

- System-proxy-only mode or TUN-only mode should each work cleanly without requiring both simultaneously.
- Company VPN (e.g. CorpLink / 飞连) must not conflict with system proxy or TUN DNS.
- TUN must not conflict with Tailscale (`100.64.0.0/10`, `fd7a:115c:a1e0::/48`, `*.ts.net`).
- When web apps (such as Gemini) render abnormally or trigger "unusual traffic", check for mismatched
  GoogleCN direct rules vs. overseas DNS, QUIC (UDP/443) exit-IP mismatch vs. TCP/WARP, and relay
  bandwidth bottlenecks.
