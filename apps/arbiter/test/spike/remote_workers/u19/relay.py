"""RW2 spike U19 (bd-6tx1xv): a TCP relay standing in for the node-side listener + mux.
usage: relay.py LISTEN TARGET MODE SECONDS [after]
  MODE  refuse | reset | stall | stall_then_drop | cut
  refuse : nothing listens for SECONDS, then it does (connection refused)
  reset  : accept and close immediately for SECONDS (socat with a dead unix peer)
  stall  : accept, hold the socket silent for SECONDS, then forward the held ones
  stall_then_drop : like stall, but close the held sockets at SECONDS
  cut    : relay normally; at SECONDS kill every established connection once
"""
import asyncio, sys, time
LISTEN, TARGET, MODE, SECS = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3], float(sys.argv[4])
T0 = time.time()
LOG = open(sys.argv[5], "a", buffering=1)
def log(m): LOG.write(f"{time.time()-T0:7.2f} {m}\n")
conns = set()
async def pipe(r, w):
    try:
        while (d := await r.read(65536)):
            w.write(d); await w.drain()
    except Exception: pass
    finally:
        try: w.close()
        except Exception: pass
async def forward(cr, cw):
    try: ur, uw = await asyncio.open_connection("127.0.0.1", TARGET)
    except Exception as e: log(f"upstream connect failed {e}"); cw.close(); return
    conns.add(cw); conns.add(uw)
    await asyncio.gather(pipe(cr, uw), pipe(ur, cw))
async def handle(cr, cw):
    el = time.time() - T0
    active = el < SECS
    if MODE == "reset" and active:
        log("reset"); cw.transport.abort(); return
    if MODE in ("stall", "stall_then_drop") and active:
        log("stall: holding connection")
        await asyncio.sleep(max(SECS - el, 0))
        if MODE == "stall_then_drop": log("drop held"); cw.transport.abort(); return
        log("release held"); await forward(cr, cw); return
    log("forward"); await forward(cr, cw)
async def main():
    srv = None
    if MODE == "refuse":
        log(f"refusing for {SECS}s"); await asyncio.sleep(SECS)
    srv = await asyncio.start_server(handle, "127.0.0.1", LISTEN, backlog=64)
    log("listening")
    if MODE == "cut":
        await asyncio.sleep(SECS); log(f"cut {len(conns)} socks")
        for w in list(conns):
            try: w.transport.abort()
            except Exception: pass
    await asyncio.Event().wait()
asyncio.run(main())
