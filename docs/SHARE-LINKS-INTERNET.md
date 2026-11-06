# Internet-reachable share links (design only)

Status: **design, not implemented, nothing deployed.** Share links today (ARCHITECTURE §7.4) work only when the
guest can reach the host directly: the same LAN or the same Tailscale tailnet. This document looks at what it
would take for a guest anywhere on the internet to open a link, what each option costs, and what it changes in
the threat model. No option here is built into paneshare.

Prices are list prices as published by each provider at the time of writing; they change, so check them before
relying on any number here.

## 1. The problem

A guest's browser must reach something that can deliver the host's video. Behind home NAT and carrier-grade NAT
the host has no inbound address, so one of these is needed:

1. **A public listener that forwards to the host** (a tunnel or a port forward). The browser keeps talking
   HTTPS + WebSocket exactly as on a LAN; only the address changes.
2. **WebRTC with NAT traversal.** The browser and host exchange offers through some **signaling** channel, try a
   direct UDP path (STUN), and fall back to a **TURN** relay when both sides are behind strict NAT (typically
   10–20% of pairs).

Either way, something on the internet carries either the traffic or at least the signaling. "No relay we host"
rules out paneshare operating it; the options below are about **who** runs it and who pays.

**Traffic size.** A guest stream is H.264 4:2:0 at balanced quality: about 1–3 Mb/s for a mostly still document
window, 5–10 Mb/s for video or scrolling. One hour at 4 Mb/s is about **1.8 GB**. Every relayed byte is billed
by relay providers.

## 2. Options

### A. Tailscale Funnel (the host user's own tailnet)

`tailscale funnel 47822` publishes a port of the host to `https://<machine>.<tailnet>.ts.net` through Tailscale's
ingress relays, with a publicly trusted certificate.

- **Cost:** free on Tailscale's Personal plan; included in paid plans. Funnel is bandwidth-limited by Tailscale
  (not published as a hard number) and best-effort.
- **Fit:** closest to today's design. The browser side doesn't change. paneshare would need to (a) detect the
  Funnel hostname and offer it as a link URL, and (b) accept a TLS-terminated connection: Funnel can either pass
  TLS through to the host (TCP mode, our certificate stays end to end) or terminate it (HTTPS mode, Tailscale's
  relay sees plaintext). **Use TCP pass-through**, so Tailscale never sees the video or the token, and switch
  the server to a certificate from `tailscale cert` for the `ts.net` name so browsers stop warning.
- **Limits:** only ports 443, 8443 and 10000; requires the host user to enable Funnel in their tailnet policy; ties
  the feature to Tailscale; relay throughput may be too low for 8+ Mb/s.
- **Who runs the relay:** Tailscale, under the host user's own account. Not paneshare.

### B. Cloudflare Tunnel (`cloudflared`) on the host user's own Cloudflare account

- **Cost:** free.
- **Fit:** same browser side. The tunnel terminates TLS at Cloudflare's edge, so Cloudflare sees plaintext
  (token, session secret, video) unless we add an application-level encryption layer.
- **Blocking problem:** Cloudflare's service terms restrict serving video or a disproportionate share of
  non-HTML content through the CDN without a paid media product. A screen stream is exactly that. **Not
  recommended.**

### C. WebRTC with public STUN and a managed TURN service

Signaling (exchanging SDP offers/answers) needs a rendezvous. Options that need no server of ours:

- **Manual copy-paste:** the link carries the host's offer; the guest's page shows an answer code the guest sends
  back to the host (chat, email). Clumsy, but zero infrastructure.
- **A static page plus a free pub/sub service** (for example a free tier of a hosted realtime channel). That's a
  third-party dependency and account, and still "deployed" in spirit.
- **The host user's own Tailscale Funnel or tunnel for signaling only**, with media going peer to peer or via TURN.

Then media: browser ⇄ host direct over UDP when possible (STUN is free: Google's and Cloudflare's public STUN
servers), otherwise via TURN.

| TURN provider | Price (list) | Free allowance | Notes |
| --- | --- | --- | --- |
| Cloudflare Realtime TURN | $0.05 per GB | First 1,000 GB per month | Anycast; credentials minted with an API key the host user owns. |
| Twilio Network Traversal Service | ≈ $0.40 per GB (US/EU; more in other regions) | none | Mature; per-region pricing. |
| Metered.ca TURN | Paid plans from ≈ $99/month for 150 GB; pay-as-you-go ≈ $0.40/GB | A small free tier (and the "Open Relay" project with a monthly cap) | Free relays are best effort and shared. |
| Xirsys | Paid plans from ≈ $33/month | A small free developer tier | |

At the 1.8 GB/hour figure, a relayed hour costs about $0.09 (Cloudflare beyond the free 1,000 GB), or $0.72
(Twilio). Most sessions wouldn't relay at all.

- **Fit:** a much bigger change. The host needs a WebRTC stack (libwebrtc via LiveKit's Swift SDK, which is
  already the planned transport upgrade, ARCHITECTURE §13.2; or pion in Go). Video moves to an RTP track
  (H.264 packetization, congestion control, NACK/PLI), which is better than TCP on lossy internet paths.
- **Credentials:** TURN credentials must not be long-lived secrets in the page. The host would mint short-lived
  credentials (Cloudflare's API returns them; coturn uses the TURN REST time-limited HMAC scheme) per link.

### D. Self-hosted coturn on the host user's own VPS

[coturn](https://github.com/coturn/coturn) is BSD-3-Clause (license compatible; it would run as a separate
service, nothing linked into paneshare).

- **Cost:** a small VPS: about $4–6/month (for example Hetzner's entry-level cloud servers, with 20 TB of traffic included in the EU;
  DigitalOcean or Vultr $4–6/month with 0.5–1 TB included, then about $0.01/GB).
- **Fit:** same as C for the host; the user operates the relay. Signaling could be served from the same VPS (a
  tiny WebSocket rendezvous), which also makes "open the link" a normal URL.
- **Effort for the user:** high (DNS, certificates, firewall, updates). It's a self-hosting feature, not a default.

### E. Direct port forward (UPnP/NAT-PMP or manual)

The router forwards a public port to the host's 47822.

- **Cost:** free.
- **Fit:** no change to the browser side; paneshare would add NAT-PMP/PCP mapping while a link is live and remove
  it afterwards.
- **Problems:** exposes the host's listener to the whole internet (scanners find new ports within minutes); many
  ISPs use CGNAT, so it often doesn't work; a self-signed certificate on a raw IP is a bad internet UX. Not
  recommended except as an expert option.

## 3. Recommendation

1. **First:** option A (Tailscale Funnel, TCP pass-through) as an opt-in "Make internet link" button shown only when
   the host has Funnel enabled. Zero cost, nothing for paneshare to operate, the browser code doesn't change, and
   TLS stays end to end with a trusted `ts.net` certificate.
2. **Later, with the LiveKit transport:** option C with Cloudflare Realtime TURN using credentials from the host
   user's own Cloudflare account (free up to 1,000 GB a month), and option D for self-hosters. Signaling through
   the same Funnel or VPS.
3. **Avoid:** B (terms of service and plaintext at the edge) and E by default (exposure).

## 4. Security changes for internet links

Everything in ARCHITECTURE §7.4 still applies; exposure to the internet adds:

- **Trusted certificates only.** On the internet, "click through the warning" is not acceptable. Use the
  Funnel/`tailscale cert` name or an ACME certificate on the user's domain; refuse to make internet links with a
  self-signed certificate.
- **Shorter default lifetime** (15 minutes) and a cap of 8 hours.
- **Global and per-address rate limits** on page loads and joins, and a lockout of the whole link after a few bad
  tokens (already 5); log every join with its address in the host panel.
- **Host approval of each join** ("Ann at 203.0.113.7 wants to view TextEdit: Allow / Deny"), because a leaked link
  is now usable from anywhere.
- **No plaintext at relays:** prefer TCP pass-through tunnels (A) or WebRTC (DTLS-SRTP end to end; a TURN relay sees
  only ciphertext). If a TLS-terminating proxy is ever used, add application-level encryption keyed from the token
  so the proxy can't read video or input.
- **Pointer control stays off by default** and is revocable; keyboard stays out of scope.
- **Turn off with hosting:** the tunnel or port mapping is created with the first internet link and removed with the
  last, like the LAN listener.

## 5. Out of scope

Running any relay, TURN server, signaling service or tunnel on paneshare's behalf; accounts; paid plans. Each option
above is operated, if at all, by the host user under their own account.
