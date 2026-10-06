#!/usr/bin/env python3 -I
"""K5 diagnostic: what does sinceTime with nanoseconds actually do, and are log timestamps unique per line?
   k5_since_probe.py <kc-dir> <pod>"""
import http.client, ssl, sys, collections
kc, pod = sys.argv[1:3]
ctx = ssl.create_default_context(cafile=f"{kc}/ca.crt"); ctx.load_cert_chain(f"{kc}/client.crt", f"{kc}/client.key")
def get(q):
    c = http.client.HTTPSConnection("127.0.0.1", 16443, context=ctx, timeout=30)
    c.request("GET", f"/api/v1/namespaces/arbiter-workers/pods/{pod}/log?container=c&timestamps=true{q}")
    r = c.getresponse(); d = r.read().decode(); c.close(); return d.split("\n")[:-1]
allv = get("")
ts = [l.split(" ", 1)[0] for l in allv]
cnt = collections.Counter(ts)
print(f"total lines {len(allv)}; distinct timestamps {len(cnt)}; max lines sharing one timestamp {max(cnt.values())}; lines in a shared-timestamp group {sum(v for v in cnt.values() if v > 1)}")
mid = ts[len(ts)//2]
print(f"sinceTime sent (ns precision): {mid}")
got = get(f"&sinceTime={mid}")
print(f"first line returned has timestamp {got[0].split(' ',1)[0]}  (older than the sinceTime sent: {got[0].split(' ',1)[0] < mid})")
sec = mid.split(".")[0] + "Z"
same_sec_before = sum(1 for t in ts if t.startswith(mid.split('.')[0]) and t < mid)
print(f"lines in the same second but BEFORE the sinceTime: {same_sec_before}; returned-from-that-second-before-since: {sum(1 for l in got if l.split(' ',1)[0] < mid)}")
print(f"truncated-to-the-second sinceTime {sec} returns {len(get('&sinceTime='+sec))} lines vs {len(got)} for the ns value")
