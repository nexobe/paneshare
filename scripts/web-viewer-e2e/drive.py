# Drives headless Chrome against server.py through the DevTools protocol and checks the share-link page.
# Development only (run.sh). Exits non-zero on the first failed check.
import asyncio, json, os, subprocess, sys, time, urllib.request
import websockets

D, CHROME = sys.argv[1], sys.argv[2]
ORIGIN = "https://127.0.0.1:47822"
LINK = "LinkID_0123456789abcd"
failures = []

def check(name, ok, detail=""):
    print(("PASS " if ok else "FAIL ") + name + (f" ({detail})" if detail else ""))
    if not ok: failures.append(name)

def inbound():
    return open(f"{D}/inbound.log").read() if os.path.exists(f"{D}/inbound.log") else ""

def command(c):
    open(f"{D}/cmd", "w").write(c)

async def main():
    chrome = subprocess.Popen([CHROME, "--headless=new", "--remote-debugging-port=9333", "--ignore-certificate-errors",
                               f"--user-data-dir={D}/prof", "--no-first-run", "--window-size=1000,700", "about:blank"],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        for _ in range(50):
            try:
                tabs = json.load(urllib.request.urlopen("http://127.0.0.1:9333/json")); break
            except Exception:
                time.sleep(0.2)
        page = [t for t in tabs if t["type"] == "page"][0]
        async with websockets.connect(page["webSocketDebuggerUrl"], max_size=None) as cdp:
            seq = [0]
            async def call(method, **params):
                seq[0] += 1; me = seq[0]
                await cdp.send(json.dumps({"id": me, "method": method, "params": params}))
                while True:
                    m = json.loads(await cdp.recv())
                    if m.get("method") == "Runtime.exceptionThrown":
                        failures.append("page exception"); print("EXCEPTION", m["params"]["exceptionDetails"].get("text"))
                    if m.get("method") == "Log.entryAdded" and "Content Security Policy" in m["params"]["entry"].get("text", ""):
                        failures.append("CSP violation"); print("CSP", m["params"]["entry"]["text"])
                    if m.get("id") == me: return m.get("result")
            async def ev(expr):
                return (await call("Runtime.evaluate", expression=expr, returnByValue=True, awaitPromise=True))["result"].get("value")
            text = lambda el: ev(f"document.getElementById('{el}').textContent")
            await call("Runtime.enable"); await call("Log.enable"); await call("Page.enable")

            await call("Page.navigate", url=f"{ORIGIN}/s/{LINK}#TOKEN_abc")
            await asyncio.sleep(1.5)
            check("token removed from the address bar", await ev("location.href") == f"{ORIGIN}/s/{LINK}")
            check("name form shown", await ev("getComputedStyle(document.getElementById('join')).display") != "none")
            await ev("document.getElementById('name').value='Ann'; document.getElementById('join').requestSubmit(); 1")
            await asyncio.sleep(2.5)
            check("joined with the token and name", '"token": "TOKEN_abc", "name": "Ann"' in inbound())
            check("form hidden after joining", await ev("getComputedStyle(document.getElementById('join')).display") == "none")
            check("title from welcome", await text("title") == "TextEdit — Notes")
            check("view only by default", await text("mode") == "View only")
            canvas = json.loads(await ev("JSON.stringify({h: document.getElementById('screen').hidden, w: document.getElementById('screen').width})"))
            check("video decoded into the canvas", not canvas["h"] and canvas["w"] == 640, str(canvas))
            px = json.loads(await ev("""JSON.stringify((() => { const x = document.getElementById('screen').getContext('2d');
                return [[320, 200], [600, 380]].map(([a, b]) => Array.from(x.getImageData(a, b, 1, 1).data.slice(0, 3))); })())"""))
            check("decoded picture is the test pattern", px[0][0] > 200 and px[0][2] < 60 and min(px[1]) > 200, str(px))
            check("session saved for reconnects", "S1" in (await ev(f"sessionStorage.getItem('paneshare.session.{LINK}')") or ""))

            r = json.loads(await ev("JSON.stringify(document.getElementById('screen').getBoundingClientRect())"))
            x, y = r["x"] + r["width"] * 0.25, r["y"] + r["height"] * 0.75
            for t in ["mouseMoved", "mousePressed", "mouseReleased"]:
                await call("Input.dispatchMouseEvent", type=t, x=x, y=y, button="left", clickCount=1)
            await asyncio.sleep(0.5)
            log = inbound()
            check("view-only pointer moves are sent", '"t":"move","x":0.25,"y":0.75' in log)
            check("view-only sends no clicks", '"t":"down"' not in log)

            command("pointer on"); await asyncio.sleep(0.6)
            check("host can grant pointer control", await text("mode") == "You can point, click and scroll")
            for t in ["mousePressed", "mouseReleased"]:
                await call("Input.dispatchMouseEvent", type=t, x=x, y=y, button="left", clickCount=1)
            await call("Input.dispatchMouseEvent", type="mouseWheel", x=x, y=y, deltaX=0, deltaY=120)
            await asyncio.sleep(0.5)
            log = inbound()
            check("clicks sent once allowed", '"t":"down","b":0,"c":1' in log)
            check("scroll sent in macOS sign", '"t":"scroll","dx":0,"dy":-120' in log)
            await call("Page.captureScreenshot", format="png")

            command("drop"); await asyncio.sleep(0.4)
            check("connection loss shown", await text("status") == "Connection lost. Reconnecting…")
            await asyncio.sleep(2.5)
            check("reconnected with the session secret", '"session": "S1", "secret": "SEC"' in inbound())
            check("picture back after reconnect", await text("status") == "")

            command("kick"); await asyncio.sleep(1.5)
            check("kick explained", await text("status") == "The host removed you from this window.")
            check("kick forgets the session", await ev(f"sessionStorage.getItem('paneshare.session.{LINK}')") is None)
            await call("Page.navigate", url=f"{ORIGIN}/s/{LINK}")
            await asyncio.sleep(1.2)
            check("used link can't be reopened", (await text("status")).startswith("This link was already used"))
            await call("Page.navigate", url=f"{ORIGIN}/s/nope#x")
            await asyncio.sleep(1.0)
            check("unknown link is a 404 page", (await ev("document.body.innerText")).startswith("This link has expired or doesn't exist"))
    finally:
        chrome.terminate()
    print("FAILED: " + ", ".join(failures) if failures else "ALL PASSED")
    sys.exit(1 if failures else 0)

asyncio.run(main())
