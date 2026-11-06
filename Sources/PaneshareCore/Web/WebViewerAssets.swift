import Foundation

/// The browser viewer the share-link server serves: one page, one stylesheet, one script, no inline
/// code (the Content-Security-Policy allows only these same-origin files) and no third-party code.
/// It decodes the host's H.264 with WebCodecs and talks to the host over one WebSocket
/// (ARCHITECTURE §7.4).
public enum WebViewerAssets {
    public static let html = #"""
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <meta name="referrer" content="no-referrer">
    <link rel="icon" href="data:,">
    <title>paneshare</title>
    <link rel="stylesheet" href="/viewer.css">
    </head>
    <body>
    <header>
      <span id="title">paneshare</span>
      <span id="mode"></span>
      <span id="expiry"></span>
    </header>
    <main>
      <p id="status">Loading…</p>
      <form id="join" hidden>
        <label for="name">Your name</label>
        <input id="name" maxlength="32" autocomplete="nickname" placeholder="Guest">
        <button type="submit">Join</button>
        <p class="note">The host sees this name next to your pointer and can remove you at any time.</p>
      </form>
      <canvas id="screen" width="16" height="10" hidden></canvas>
    </main>
    <script src="/viewer.js"></script>
    </body>
    </html>
    """#

    public static let css = #"""
    [hidden] { display: none !important; }
    :root { color-scheme: light dark; font: 14px -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
    body { margin: 0; height: 100vh; height: 100dvh; overflow: hidden; display: flex; flex-direction: column; background: #1e1e1e; color: #eee; }
    header { display: flex; gap: 12px; align-items: center; padding: 6px 12px; background: #2a2a2a; font-size: 13px; }
    #title { font-weight: 600; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    #mode { padding: 1px 8px; border-radius: 9px; background: #444; }
    #mode[data-pointer="1"] { background: #2d6a3e; }
    #expiry { margin-left: auto; opacity: .7; }
    main { flex: 1; display: flex; flex-direction: column; align-items: center; justify-content: center; min-height: 0; }
    #status { opacity: .85; text-align: center; max-width: 36em; }
    #status[data-kind="error"] { color: #ff8a80; }
    form { display: flex; flex-direction: column; gap: 8px; width: 18em; }
    input, button { font: inherit; padding: 6px 8px; border-radius: 6px; border: 1px solid #555; background: #333; color: inherit; }
    button { background: #3b6fd8; border-color: #3b6fd8; cursor: pointer; }
    .note { font-size: 12px; opacity: .7; margin: 0; }
    canvas { max-width: 100%; max-height: calc(100vh - 32px); max-height: calc(100dvh - 32px); width: auto; height: auto; cursor: default; touch-action: none; transform-origin: 0 0; }
    @media (max-height: 480px) {
      header { display: none; }
      canvas { max-height: 100vh; max-height: 100dvh; }
    }
    canvas[data-pointer="1"] { cursor: pointer; }
    """#

    public static let js = #"""
    "use strict";
    (() => {
      const $ = (id) => document.getElementById(id);
      const canvas = $("screen");
      const ctx = canvas.getContext("2d");
      const link = location.pathname.split("/")[2] || "";
      const storeKey = "paneshare.session." + link;
      let token = location.hash.length > 1 ? location.hash.slice(1) : null;
      // Keep the one-time token out of the address bar and history.
      if (location.hash) history.replaceState(null, "", location.pathname);
      let saved = null;
      try { saved = JSON.parse(sessionStorage.getItem(storeKey) || "null"); } catch (_) { saved = null; }

      let ws = null, decoder = null, decoderKey = "", waitingKey = true, pointerAllowed = false;
      let ended = false, retries = 0, lastMove = 0, waitingPicture = true;

      function status(text, kind) {
        const el = $("status");
        el.textContent = text;
        el.dataset.kind = kind || "";
        el.hidden = !text;
      }
      function setPointer(allowed) {
        pointerAllowed = !!allowed;
        $("mode").textContent = pointerAllowed ? "You can point, click and scroll" : "View only";
        $("mode").dataset.pointer = pointerAllowed ? "1" : "0";
        canvas.dataset.pointer = pointerAllowed ? "1" : "0";
      }
      function send(obj) { if (ws && ws.readyState === 1) ws.send(JSON.stringify(obj)); }
      function b64(s) { return Uint8Array.from(atob(s), (c) => c.charCodeAt(0)); }

      if (!("VideoDecoder" in window) || !("EncodedVideoChunk" in window)) {
        status("This browser can't show the window: it needs WebCodecs (Chrome or Edge 94+, Safari 16.4+, Firefox 130+).", "error");
        return;
      }
      if (!window.isSecureContext) {
        status("Open the link with https:// so the browser allows video decoding.", "error");
        return;
      }
      if (!token && !saved) {
        status("This link was already used, or it's incomplete. Ask the host for a new link.", "error");
        return;
      }

      const endings = {
        4001: "The link has expired.",
        4002: "This link isn't valid any more. Ask the host for a new link.",
        4003: "The host removed you from this window.",
        4004: "The host closed this window.",
        4005: "The host stopped sharing.",
        4006: "Too many people are connected right now. Try again later.",
        4007: "Something went wrong. Reload the page to try again.",
        4008: "This window is open in another tab."
      };

      function connect(name) {
        status(saved ? "Reconnecting…" : "Connecting…");
        ws = new WebSocket("wss://" + location.host + "/ws");
        ws.binaryType = "arraybuffer";
        ws.onopen = () => {
          const scale = Math.min(2, Math.max(1, window.devicePixelRatio || 1));
          send(saved ? { t: "join", link, session: saved.session, secret: saved.secret, scale }
                     : { t: "join", link, token, name, scale });
        };
        ws.onmessage = (e) => {
          if (typeof e.data === "string") {
            let m = null;
            try { m = JSON.parse(e.data); } catch (_) { return; }
            onNotice(m);
          } else {
            onVideo(e.data);
          }
        };
        ws.onclose = (e) => {
          ws = null;
          if (ended) return;
          if (endings[e.code]) {
            ended = true;
            if (e.code !== 4006 && e.code !== 4008) sessionStorage.removeItem(storeKey);
            canvas.hidden = true;
            status(endings[e.code], "error");
            return;
          }
          if (!saved) { status("Couldn't reach the host. Reload the page to try again.", "error"); return; }
          const delay = Math.min(10000, 500 * Math.pow(2, retries++));
          status("Connection lost. Reconnecting…");
          setTimeout(() => connect(), delay);
        };
      }

      function onNotice(m) {
        switch (m.t) {
          case "welcome":
            saved = { session: m.session, secret: m.secret || (saved && saved.secret) };
            sessionStorage.setItem(storeKey, JSON.stringify(saved));
            token = null;
            retries = 0;
            if (m.title) { $("title").textContent = m.title; document.title = m.title + " — paneshare"; }
            setPointer(m.pointer);
            if (m.expires) {
              const at = new Date(m.expires);
              $("expiry").textContent = "Link ends at " + at.toLocaleString([], { month: "short", day: "numeric", hour: "2-digit", minute: "2-digit" });
            }
            waitingPicture = true;
            status("Waiting for the picture…");
            break;
          case "started":
            if (m.pw && m.ph) { canvas.width = m.pw; canvas.height = m.ph; }
            break;
          case "config":
            configure(m.codec, m.description);
            break;
          case "pointer":
            setPointer(m.pointer);
            break;
        }
      }

      function configure(codec, description) {
        const key = codec + "|" + description;
        if (decoder && decoder.state === "configured" && key === decoderKey) return;
        if (decoder && decoder.state !== "closed") decoder.close();
        decoder = new VideoDecoder({
          output: (frame) => {
            if (canvas.width !== frame.displayWidth || canvas.height !== frame.displayHeight) {
              canvas.width = frame.displayWidth;
              canvas.height = frame.displayHeight;
            }
            ctx.drawImage(frame, 0, 0);
            frame.close();
            if (waitingPicture) { waitingPicture = false; canvas.hidden = false; status(""); }
          },
          error: (err) => {
            console.warn("decoder error", err);
            decoderKey = "";
            waitingKey = true;
            send({ t: "kf" });
          }
        });
        decoder.configure({ codec, description: b64(description), optimizeForLatency: true });
        decoderKey = key;
        waitingKey = true;
      }

      function onVideo(buffer) {
        const view = new DataView(buffer);
        if (buffer.byteLength < 11 || view.getUint8(0) !== 1) return;
        const isKey = (view.getUint8(1) & 1) === 1;
        if (!decoder || decoder.state !== "configured") return;
        if (waitingKey && !isKey) return;
        if (!isKey && decoder.decodeQueueSize > 3) { waitingKey = true; send({ t: "kf" }); return; }
        waitingKey = false;
        const timestamp = Number(view.getBigUint64(2));
        decoder.decode(new EncodedVideoChunk({ type: isKey ? "key" : "delta", timestamp, data: new Uint8Array(buffer, 10) }));
      }

      function point(e) {
        const r = canvas.getBoundingClientRect();
        return { x: (e.clientX - r.left) / r.width, y: (e.clientY - r.top) / r.height };
      }
      // Touch: tap clicks, drag drags, long press right-clicks, two fingers scroll, and a pinch
      // zooms and moves the picture here only. A two-finger tap puts the picture back.
      const fingers = new Map();
      const LONG_PRESS = 500, SLOP = 8, PINCH = 16;
      let touch = null, zoom = { k: 1, x: 0, y: 0 }, lastTap = { at: 0, x: 0, y: 0, count: 0 };
      function showZoom() {
        canvas.style.transform = zoom.k === 1 && !zoom.x && !zoom.y ? "" : "translate(" + zoom.x + "px," + zoom.y + "px) scale(" + zoom.k + ")";
      }
      function fingerFacts() {
        const [a, b] = [...fingers.values()];
        return { d: Math.hypot(a.x - b.x, a.y - b.y), x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 };
      }
      function endOneFinger() {
        if (touch && touch.timer) clearTimeout(touch.timer);
      }
      function touchDown(e) {
        canvas.setPointerCapture(e.pointerId);
        fingers.set(e.pointerId, { x: e.clientX, y: e.clientY });
        e.preventDefault();
        if (fingers.size === 1) {
          const p = point(e);
          touch = { kind: "wait", startX: e.clientX, startY: e.clientY, p, timer: null };
          if (pointerAllowed) {
            touch.timer = setTimeout(() => {
              if (!touch || touch.kind !== "wait") return;
              touch.kind = "done";
              send(Object.assign({ t: "down", b: 2, c: 1 }, touch.p));
              send(Object.assign({ t: "up", b: 2, c: 1 }, touch.p));
            }, LONG_PRESS);
          }
          send(Object.assign({ t: "move" }, p));
        } else if (fingers.size === 2) {
          if (touch && touch.kind === "drag") send(Object.assign({ t: "up", b: 0, c: 1 }, touch.last));
          endOneFinger();
          const f = fingerFacts();
          touch = { kind: "two", d0: f.d, x: f.x, y: f.y, d: f.d, moved: false, startedAt: performance.now() };
        }
      }
      function touchMove(e) {
        if (!fingers.has(e.pointerId)) return;
        fingers.set(e.pointerId, { x: e.clientX, y: e.clientY });
        if (!touch) return;
        if (touch.kind === "wait" || touch.kind === "drag") {
          const p = point(e);
          if (touch.kind === "wait") {
            if (Math.hypot(e.clientX - touch.startX, e.clientY - touch.startY) < SLOP) return;
            endOneFinger();
            touch.kind = "drag";
            if (pointerAllowed) send(Object.assign({ t: "down", b: 0, c: 1 }, touch.p));
          }
          touch.last = p;
          send(Object.assign({ t: "move" }, p));
        } else if (touch.kind === "two" || touch.kind === "scroll" || touch.kind === "pinch") {
          if (fingers.size !== 2) return;
          const f = fingerFacts(), dx = f.x - touch.x, dy = f.y - touch.y;
          if (touch.kind === "two") {
            if (Math.abs(f.d - touch.d0) >= PINCH) touch.kind = "pinch";
            else if (Math.hypot(dx, dy) >= SLOP) touch.kind = "scroll";
            else return;
            touch.moved = true;
          }
          if (touch.kind === "pinch") {
            const k = Math.min(5, Math.max(1, zoom.k * f.d / touch.d));
            const r = canvas.getBoundingClientRect();
            // The point that was between the fingers stays between them.
            const ox = (touch.x - r.left) / zoom.k, oy = (touch.y - r.top) / zoom.k;
            zoom.x += dx + (zoom.k - k) * ox;
            zoom.y += dy + (zoom.k - k) * oy;
            zoom.k = k;
            if (k === 1) { zoom.x = 0; zoom.y = 0; }
            showZoom();
          } else if (pointerAllowed) {
            const c = point({ clientX: f.x, clientY: f.y });
            send(Object.assign({ t: "scroll", dx, dy }, c));
          }
          touch.x = f.x; touch.y = f.y; touch.d = f.d;
        }
      }
      function touchUp(e, cancelled) {
        if (!fingers.delete(e.pointerId) || !touch) return;
        if (touch.kind === "two" && !touch.moved && !cancelled && performance.now() - touch.startedAt < 400) {
          zoom = { k: 1, x: 0, y: 0 };
          showZoom();
          touch = fingers.size ? { kind: "done" } : null;
          return;
        }
        if (touch.kind === "drag") {
          if (pointerAllowed) send(Object.assign({ t: "up", b: 0, c: 1 }, point(e)));
        } else if (touch.kind === "wait" && !cancelled && pointerAllowed) {
          endOneFinger();
          const now = performance.now();
          const again = now - lastTap.at < 350 && Math.hypot(e.clientX - lastTap.x, e.clientY - lastTap.y) < 24;
          const c = again ? Math.min(3, lastTap.count + 1) : 1;
          lastTap = { at: now, x: e.clientX, y: e.clientY, count: c };
          send(Object.assign({ t: "down", b: 0, c }, touch.p));
          send(Object.assign({ t: "up", b: 0, c }, touch.p));
        }
        endOneFinger();
        touch = fingers.size ? { kind: "done" } : null;
        if (!fingers.size) send({ t: "leave" });
      }
      canvas.addEventListener("pointercancel", (e) => {
        if (e.pointerType === "touch") return touchUp(e, true);
        send(Object.assign({ t: "up", b: e.button < 0 ? 0 : e.button, c: 1 }, point(e)));
      });
      canvas.addEventListener("pointermove", (e) => {
        if (e.pointerType === "touch") return touchMove(e);
        const now = performance.now();
        if (now - lastMove < 16) return;
        lastMove = now;
        send(Object.assign({ t: "move" }, point(e)));
      });
      canvas.addEventListener("pointerleave", (e) => { if (e.pointerType !== "touch") send({ t: "leave" }); });
      canvas.addEventListener("pointerdown", (e) => {
        if (e.pointerType === "touch") return touchDown(e);
        if (!pointerAllowed) return;
        canvas.setPointerCapture(e.pointerId);
        send(Object.assign({ t: "down", b: e.button, c: Math.min(3, Math.max(1, e.detail || 1)) }, point(e)));
        e.preventDefault();
      });
      canvas.addEventListener("pointerup", (e) => {
        if (e.pointerType === "touch") return touchUp(e, false);
        send(Object.assign({ t: "up", b: e.button, c: Math.min(3, Math.max(1, e.detail || 1)) }, point(e)));
      });
      canvas.addEventListener("wheel", (e) => {
        if (!pointerAllowed) return;
        e.preventDefault();
        const k = e.deltaMode === 1 ? 16 : e.deltaMode === 2 ? 400 : 1;
        // DOM deltas are positive when the page scrolls down; macOS's are the opposite.
        send(Object.assign({ t: "scroll", dx: -e.deltaX * k, dy: -e.deltaY * k }, point(e)));
      }, { passive: false });
      canvas.addEventListener("contextmenu", (e) => { if (pointerAllowed) e.preventDefault(); });
      document.addEventListener("visibilitychange", () => { if (!document.hidden) send({ t: "kf" }); });

      if (saved) {
        connect();
      } else {
        status("");
        const form = $("join");
        form.hidden = false;
        $("name").focus();
        form.addEventListener("submit", (e) => {
          e.preventDefault();
          form.hidden = true;
          connect($("name").value.trim().slice(0, 32) || "Guest");
        });
      }
    })();
    """#
}
