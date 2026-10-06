// RW2 spike (bd-6tx1xv) U1, the part this host cannot do for itself: run THIS from a
// DIFFERENT tailnet device (Node >= 22, built-in WebSocket; no npm) while
// serve_soak.sh is running on the primary, so the bytes cross the real WireGuard
// path (direct or DERP) and any tailnet ACL.
//
//   node remote_peer_check.mjs wss://<primary>.<tailnet>.ts.net:8444/node/socket/websocket?vsn=2.0.0\&token=spike-token [seconds=120] [hb_s=10]
//
// It joins `node:spike`, sends the design's `hb` every hb_s, and prints each ack's
// round trip. Exit 0 = the socket stayed open for the whole period and every
// heartbeat was acked; exit 1 otherwise. Also check the plain-HTTP half with:
//   curl -sS https://<primary>.<tailnet>.ts.net:8444/nodes/ping     (expect: pong)
//   curl -sS -o /dev/null -w '%{http_code}\n' https://<primary>.<tailnet>.ts.net:8444/   (expect: 404)
const [url, secs = "120", hbS = "10"] = process.argv.slice(2);
if (!url) { console.error("usage: node remote_peer_check.mjs <wss-url> [seconds] [hb_s]"); process.exit(2); }
const ws = new WebSocket(url);
let seq = 0, acked = 0, closed = false;
const sent = new Map();
const rtts = [];
ws.onopen = () => {
  ws.send(JSON.stringify(["1", "1", "node:spike", "phx_join", {}]));
  const hb = setInterval(() => {
    seq += 1; sent.set(seq, performance.now());
    ws.send(JSON.stringify(["1", String(seq + 1), "node:spike", "hb", { seq, t: Date.now() }]));
  }, Number(hbS) * 1000);
  setTimeout(() => {
    clearInterval(hb);
    setTimeout(() => {
      const ok = !closed && acked === seq && seq > 0;
      console.log(JSON.stringify({ seconds: Number(secs), hb_s: Number(hbS), sent: seq, acked, closed, rtt_ms: rtts, ok }));
      ws.close();
      process.exit(ok ? 0 : 1);
    }, 3000);
  }, Number(secs) * 1000);
};
ws.onmessage = (ev) => {
  const [, , topic, event, payload] = JSON.parse(ev.data);
  if (topic === "node:spike" && event === "hb_ack" && sent.has(payload.seq)) {
    acked += 1; rtts.push(Math.round(performance.now() - sent.get(payload.seq)));
  }
};
ws.onclose = (ev) => { closed = true; console.error("closed", ev.code, ev.reason); };
ws.onerror = () => { console.error("websocket error"); };
