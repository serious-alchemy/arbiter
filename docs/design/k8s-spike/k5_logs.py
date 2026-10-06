#!/usr/bin/env python3 -I
"""K5 spike: pods/log follow + resume client (stdlib only). Not product code.

  k5_logs.py <kc-dir> <pod> [--disconnect-every S] [--long N] [--pad N] [--since-probe]

Follows `GET .../pods/<pod>/log?follow=true&timestamps=true`, drops the connection every S seconds, resumes with
sinceTime=<last timestamp as seen> and de-duplicates by (timestamp, sha1(line)); finally does one non-follow read from the
cursor to EOF (K§3.4). Validates that every producer sequence number 1..N appears exactly once and that each line is intact.
"""
import hashlib, http.client, json, re, ssl, subprocess, sys, time, argparse

ap = argparse.ArgumentParser()
ap.add_argument("kc"); ap.add_argument("pod")
ap.add_argument("--ns", default="arbiter-workers"); ap.add_argument("--container", default="c")
ap.add_argument("--disconnect-every", type=float, default=2.0)
ap.add_argument("--long", type=int, default=40000); ap.add_argument("--pad", type=int, default=100)
ap.add_argument("--server", default="127.0.0.1:16443")
ap.add_argument("--dedupe-window-s", type=float, default=0.0, help="keep (ts,hash) of lines newer than last_ts - window")
a = ap.parse_args()

ctx = ssl.create_default_context(cafile=f"{a.kc}/ca.crt")
ctx.load_cert_chain(f"{a.kc}/client.crt", f"{a.kc}/client.key")
host, port = a.server.split(":")

def parse_ts(s):  # '2026-10-06T10:20:07.172418792Z' -> (epoch_seconds_int, nanos)
    m = re.match(r"(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)(?:\.(\d+))?Z$", s)
    import calendar
    sec = calendar.timegm(tuple(int(x) for x in m.groups()[:6]) + (0, 0, 0))
    return sec * 10**9 + int((m.group(7) or "0").ljust(9, "0"))

def open_log(follow, since=None):
    q = f"container={a.container}&timestamps=true" + ("&follow=true" if follow else "") + (f"&sinceTime={since}" if since else "")
    c = http.client.HTTPSConnection(host, int(port), context=ctx, timeout=30)
    c.request("GET", f"/api/v1/namespaces/{a.ns}/pods/{a.pod}/log?{q}")
    r = c.getresponse()
    if r.status != 200: raise SystemExit(f"HTTP {r.status}: {r.read()[:200]}")
    return c, r

lines = []          # accepted lines: (ts_ns, ts_str, content)
seen = set()        # (ts_ns, sha1) of lines at/after the dedupe horizon
last_ts_str = None; last_ns = 0
dupes = 0; resumes = 0; raw_total = 0; since_sent = []

def feed(raw_line):
    global last_ts_str, last_ns, dupes, raw_total
    raw_total += 1
    ts, _, content = raw_line.partition(" ")
    ns = parse_ts(ts); h = hashlib.sha1(content.encode("utf-8", "replace")).hexdigest()
    key = (ns, h)
    if key in seen: dupes += 1; return
    seen.add(key); lines.append((ns, ts, content))
    if ns >= last_ns: last_ns, last_ts_str = ns, ts
    # prune: keep only keys within the dedupe window of the newest timestamp
    if len(seen) > 200000:
        horizon = last_ns - int(max(a.dedupe_window_s, 1.0) * 10**9) - 10**9
        for k in [k for k in seen if k[0] < horizon]: seen.discard(k)

def follow_until(deadline):
    global resumes
    since = last_ts_str
    if since: since_sent.append(since)
    c, r = open_log(True, since)
    resumes += 1 if since else 0
    buf = b""
    t_end = time.time() + (deadline or 10**9)
    try:
        while time.time() < t_end:
            chunk = r.read1(65536)
            if not chunk: return True   # EOF: container finished and the log is complete
            buf += chunk
            while True:
                i = buf.find(b"\n")
                if i < 0: break
                feed(buf[:i].decode("utf-8", "replace")); buf = buf[i+1:]
    except (TimeoutError, OSError):
        pass
    finally:
        c.close()
    return False

done = False
while not done:
    done = follow_until(a.disconnect_every)
# final drain, non-follow, from the cursor
c, r = open_log(False, last_ts_str)
data = r.read().decode("utf-8", "replace"); c.close()
for l in data.split("\n"):
    if l: feed(l)

seqs = []; bad = 0; long_ok = 0; end_line = None
for ns, ts, content in lines:
    m = re.match(r"S(\d{8}) (x*|y*)$", content)
    if m:
        seqs.append(int(m.group(1)))
        tail = m.group(2)
        if tail.startswith("y"):
            if len(tail) == a.long: long_ok += 1
            else: bad += 1
        elif len(tail) != a.pad: bad += 1
    elif content.startswith("END "): end_line = content
    else: bad += 1
want = int(end_line.split()[1]) if end_line else (max(seqs) if seqs else 0)
missing = sorted(set(range(1, want + 1)) - set(seqs)); dup_seq = len(seqs) - len(set(seqs))
print(json.dumps({"lines_accepted": len(lines), "raw_lines_received": raw_total, "duplicates_dropped_by_dedupe": dupes,
                  "resumes": resumes, "producer_last_seq": want, "missing": len(missing), "missing_first": missing[:5],
                  "duplicate_sequence_numbers_accepted": dup_seq, "corrupt_lines": bad, "long_lines_intact": long_ok,
                  "sinceTime_values_sent_first3": since_sent[:3]}))
