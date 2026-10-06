import json, sys, time, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
LOG = open(sys.argv[2], "a", buffering=1)
def log(*a): LOG.write(f"{time.time():.3f} " + " ".join(str(x) for x in a) + "\n")
class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    def do_GET(self):
        log("GET", self.path); self.send_response(404); self.send_header("content-length","0"); self.end_headers()
    def do_HEAD(self): self.do_GET()
    def do_POST(self):
        n = int(self.headers.get("content-length") or 0); body = self.rfile.read(n)
        try: req = json.loads(body)
        except Exception: req = {}
        stream = bool(req.get("stream"))
        log("POST", self.path, "stream=", stream, "model=", req.get("model"), "bytes=", n)
        if not self.path.startswith("/v1/messages"):
            self.send_response(200); self.send_header("content-type","application/json"); b=b"{}"; self.send_header("content-length",str(len(b))); self.end_headers(); self.wfile.write(b); return
        msg = {"id":"msg_spike","type":"message","role":"assistant","model":req.get("model","claude-spike"),"content":[],"stop_reason":None,"stop_sequence":None,"usage":{"input_tokens":10,"output_tokens":1}}
        text = "PONG-FROM-FAKE-API"
        if not stream:
            msg.update(content=[{"type":"text","text":text}], stop_reason="end_turn")
            b = json.dumps(msg).encode()
            self.send_response(200); self.send_header("content-type","application/json"); self.send_header("content-length",str(len(b))); self.end_headers(); self.wfile.write(b); return
        self.send_response(200); self.send_header("content-type","text/event-stream"); self.send_header("cache-control","no-cache"); self.send_header("transfer-encoding","chunked"); self.end_headers()
        def ev(name, data):
            payload = f"event: {name}\ndata: {json.dumps(data)}\n\n".encode()
            self.wfile.write(f"{len(payload):x}\r\n".encode()+payload+b"\r\n"); self.wfile.flush()
        ev("message_start", {"type":"message_start","message":msg})
        ev("content_block_start", {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}})
        ev("ping", {"type":"ping"})
        for part in ["PONG-", "FROM-", "FAKE-API"]:
            ev("content_block_delta", {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":part}}); time.sleep(float(sys.argv[3]) if len(sys.argv)>3 else 0)
        ev("content_block_stop", {"type":"content_block_stop","index":0})
        ev("message_delta", {"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":None},"usage":{"output_tokens":6}})
        ev("message_stop", {"type":"message_stop"})
        self.wfile.write(b"0\r\n\r\n"); self.wfile.flush(); log("served ok")
ThreadingHTTPServer.allow_reuse_address = True
srv = ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H)
if len(sys.argv) > 5:
    import ssl
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); ctx.load_cert_chain(sys.argv[4], sys.argv[5])
    srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
srv.serve_forever()
