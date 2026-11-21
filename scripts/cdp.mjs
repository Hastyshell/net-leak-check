// Drives a headless Chrome over the DevTools protocol (needs Node >= 22 for global WebSocket).
// Usage:
//   node cdp.mjs <port> webrtc                 -> ICE candidates gathered with public STUN servers
//   node cdp.mjs <port> policy                 -> WebRTC / DoH / proxy rows from chrome://policy
//   node cdp.mjs <port> page <url> <out.png> [waitMs]
//                                              -> icon-font status, failed/pending requests, "unusual traffic" check, screenshot
import { writeFileSync } from "node:fs";

const [port, cmd, ...rest] = process.argv.slice(2);
const page = (await (await fetch(`http://127.0.0.1:${port}/json/list`)).json()).find((t) => t.type === "page");
const ws = new WebSocket(page.webSocketDebuggerUrl);
await new Promise((r) => ws.addEventListener("open", r));
let seq = 0;
const listeners = [];
ws.addEventListener("message", (m) => {
  const d = JSON.parse(m.data);
  for (const l of listeners) l(d);
});
const call = (method, params = {}) =>
  new Promise((res) => {
    const id = ++seq;
    const l = (d) => {
      if (d.id === id) {
        listeners.splice(listeners.indexOf(l), 1);
        res(d.result ?? d);
      }
    };
    listeners.push(l);
    ws.send(JSON.stringify({ id, method, params }));
  });
const evaluate = async (expression, awaitPromise = false) =>
  (await call("Runtime.evaluate", { expression, awaitPromise, returnByValue: true })).result?.value;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

if (cmd === "webrtc") {
  const list = await evaluate(
    `new Promise((resolve) => {
      const found = [];
      const pc = new RTCPeerConnection({ iceServers: [
        { urls: "stun:stun.l.google.com:19302" }, { urls: "stun:stun.cloudflare.com:3478" } ] });
      pc.createDataChannel("x");
      pc.onicecandidate = (e) => {
        if (e.candidate && e.candidate.candidate) {
          const p = e.candidate.candidate.split(" ");
          found.push(p[7] + " " + p[2] + " " + p[4]);
        }
      };
      pc.createOffer().then((o) => pc.setLocalDescription(o));
      setTimeout(() => resolve([...new Set(found)]), 7000);
    })`,
    true,
  );
  console.log(list?.length ? list.join("\n") : "(no candidates)");
} else if (cmd === "policy") {
  await call("Page.navigate", { url: "chrome://policy" });
  await sleep(3000);
  // chrome://policy renders inside shadow roots; walk them for text.
  const text = await evaluate(`(function w(n){let t="";if(n.shadowRoot)t+=w(n.shadowRoot);
    for(const c of n.childNodes){t+=c.nodeType===3?c.textContent+" ":w(c);}return t;})(document.body).replace(/\\s+/g," ")`);
  for (const name of ["WebRtcIPHandling", "WebRtcIPHandlingPolicy", "DnsOverHttpsMode", "DnsOverHttpsTemplates", "ProxyMode", "ProxySettings"]) {
    const i = text.indexOf(name + " ");
    if (i >= 0) console.log(text.slice(i, i + 110).split(/ (错误|Error|值|Value) /)[0]);
  }
} else if (cmd === "page") {
  const [url, out, wait = "30000"] = rest;
  const reqs = new Map();
  listeners.push((d) => {
    const p = d.params;
    if (d.method === "Network.requestWillBeSent") reqs.set(p.requestId, { url: p.request.url, type: p.type });
    if (d.method === "Network.loadingFinished") Object.assign(reqs.get(p.requestId) ?? {}, { done: true });
    if (d.method === "Network.loadingFailed") Object.assign(reqs.get(p.requestId) ?? {}, { err: p.errorText });
  });
  await call("Network.enable");
  await call("Page.navigate", { url });
  await sleep(Number(wait));
  const fonts = await evaluate(
    `JSON.stringify([...document.fonts].filter(f=>/symbol|icon|material/i.test(f.family)).map(f=>f.family+":"+f.status))`,
  );
  const body = (await evaluate("document.body ? document.body.innerText.slice(0, 2000) : ''")) ?? "";
  console.log("title:", await evaluate("document.title"));
  console.log("icon fonts:", fonts);
  if (/unusual traffic|异常流量|\/sorry\//i.test(body + (await evaluate("location.href"))))
    console.log("GOOGLE_UNUSUAL_TRAFFIC:", body.replace(/\s+/g, " ").slice(0, 200));
  const byHost = {};
  let pending = 0;
  for (const r of reqs.values()) {
    const h = new URL(r.url).host;
    if (r.err) byHost[`${h} ${r.err}`] = (byHost[`${h} ${r.err}`] ?? 0) + 1;
    else if (!r.done) pending++;
  }
  console.log("requests:", reqs.size, "pending:", pending);
  for (const [k, n] of Object.entries(byHost)) console.log(`failed: ${n}x ${k}`);
  const shot = await call("Page.captureScreenshot", { format: "png" });
  if (shot.data) writeFileSync(out, Buffer.from(shot.data, "base64"));
}
process.exit(0);
