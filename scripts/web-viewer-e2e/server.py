# Mock share-link host for run.sh: replays fixtures written by WebViewerFixtureTests. Development only.
import base64, glob, hashlib, json, os, socket, ssl, struct, sys, threading, time

D = sys.argv[1]
LINK, TOKEN = "LinkID_0123456789abcd", "TOKEN_abc"
resp = {k: open(f"{D}/resp-{k}.bin", "rb").read() for k in ["page", "js", "css", "gone"]}
frames = sorted(glob.glob(f"{D}/out/*"))
log = open(f"{D}/inbound.log", "a", buffering=1)

def ws_send(conn, opcode, payload):
    n = len(payload)
    if n < 126: head = bytes([0x80 | opcode, n])
    elif n < 65536: head = bytes([0x80 | opcode, 126]) + struct.pack(">H", n)
    else: head = bytes([0x80 | opcode, 127]) + struct.pack(">Q", n)
    conn.sendall(head + payload)

def ws_recv(conn, buf):
    while True:
        if len(buf) >= 2:
            ln = buf[1] & 0x7F; off = 2
            if ln == 126: ln = struct.unpack(">H", buf[2:4])[0]; off = 4
            if len(buf) >= off + 4 + ln:
                mask = buf[off:off + 4]; p = bytes(b ^ mask[i % 4] for i, b in enumerate(buf[off + 4:off + 4 + ln]))
                op = buf[0] & 0x0F
                del buf[:off + 4 + ln]
                return op, p
        d = conn.recv(65536)
        if not d: return None, None
        buf += d

def handle(conn):
    data = b""
    while b"\r\n\r\n" not in data:
        d = conn.recv(4096)
        if not d: return
        data += d
    head = data.split(b"\r\n\r\n")[0].decode()
    path = head.split(" ")[1]
    hdrs = {l.split(":", 1)[0].lower(): l.split(":", 1)[1].strip() for l in head.split("\r\n")[1:]}
    log.write(f"HTTP {path} origin={hdrs.get('origin')}\n")
    if path != "/ws":
        r = resp["page"] if path == f"/s/{LINK}" else resp["js"] if path == "/viewer.js" else resp["css"] if path == "/viewer.css" else resp["gone"]
        conn.sendall(r); conn.close(); return
    acc = base64.b64encode(hashlib.sha1((hdrs["sec-websocket-key"] + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
    conn.sendall(f"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {acc}\r\n\r\n".encode())
    buf = bytearray()
    op, p = ws_recv(conn, buf)
    join = json.loads(p)
    log.write("JOIN " + json.dumps(join) + "\n")
    ok = join.get("link") == LINK and (join.get("token") == TOKEN or (join.get("session") == "S1" and join.get("secret") == "SEC"))
    if not ok:
        ws_send(conn, 8, struct.pack(">H", 4002)); conn.close(); return
    ws_send(conn, 1, json.dumps({"t": "welcome", "session": "S1", "secret": "SEC" if join.get("token") else None,
                                 "title": "TextEdit — Notes", "pointer": False, "expires": (time.time() + 3600) * 1000}).encode())
    ws_send(conn, 1, open(f"{D}/started.txt", "rb").read())
    alive = [True]
    def reader():
        while alive[0]:
            op, p = ws_recv(conn, buf)
            if op is None or op == 8: alive[0] = False; return
            if op == 1: log.write("MSG " + p.decode() + "\n")
    threading.Thread(target=reader, daemon=True).start()
    def streamer():
        for f in frames:
            if not alive[0]: return
            try: ws_send(conn, 1 if f.endswith(".txt") else 2, open(f, "rb").read())
            except Exception: return
            if f.endswith(".bin"): time.sleep(1 / 30)
        log.write("STREAM DONE\n")
    threading.Thread(target=streamer, daemon=True).start()
    def hard_close():
        alive[0] = False
        try: conn.shutdown(socket.SHUT_RDWR)
        except Exception: pass
        conn.close()
    while alive[0]:
        cmd = ""
        if os.path.exists(f"{D}/cmd"):
            cmd = open(f"{D}/cmd").read().strip(); os.remove(f"{D}/cmd")
        if cmd == "pointer on":
            ws_send(conn, 1, json.dumps({"t": "pointer", "pointer": True}).encode()); log.write("SENT pointer on\n")
        elif cmd == "kick":
            ws_send(conn, 8, struct.pack(">H", 4003) + b"kicked"); log.write("SENT kick\n"); time.sleep(0.5); hard_close(); return
        elif cmd == "drop":
            log.write("DROP\n"); hard_close(); return
        time.sleep(0.1)

ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(f"{D}/cert.pem", f"{D}/key.pem")
ctx.set_alpn_protocols(["http/1.1"])
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 47822)); s.listen(16)
print("listening", flush=True)
while True:
    c, _ = s.accept()
    try:
        tc = ctx.wrap_socket(c, server_side=True)
    except Exception as e:
        log.write(f"TLS fail {e}\n"); continue
    threading.Thread(target=handle, args=(tc,), daemon=True).start()
