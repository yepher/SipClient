# Inbound Calls — NAT / Firewall Setup

The Inbound tab listens for incoming SIP INVITEs and audio (RTP). For
the LAN this works out of the box: anything on the same network can
reach the listener at `<your-mac-ip>:5060`. From the public internet
it doesn't, because your home/office NAT and firewall sit between the
caller and your Mac. This document covers what to open up for inbound
calls to reach you.

The client does **not** support SIP REGISTER (LiveKit and many other
SIP services don't either), so we can't use the "register and let the
server push calls back over the open connection" trick. Inbound calls
have to reach you directly. That means either:

1. **STUN-discovered RTP + manual forward / SSH tunnel for SIP**
   (recommended). The Inbound tab runs STUN automatically for the RTP
   socket on listener start; on cone NATs (almost all home routers),
   the discovered public IP:port is the same one the peer's RTP will
   land on, and we put it straight into the answer SDP. You only need
   to handle the SIP signaling path — typically by forwarding port
   5060 or running an SSH tunnel.
2. **Static port forwarding** on your router for both SIP and RTP
   (works without STUN; useful when you want stable predictable
   ports).
3. **A tunnel service** (ngrok, Tailscale Funnel, Cloudflare Tunnel
   …) for ad-hoc setups where you can't touch the router.

Either way, the SIP server (e.g. LiveKit) needs to know a SIP address
it can reach you at. That public `host:port` goes in the **Public
address** fields under the Inbound tab. The RTP path is handled by
STUN unless you override it.

---

## Ports the client needs reachable

| What           | Default local port | Protocol                           |
|----------------|--------------------|------------------------------------|
| SIP signaling  | `5060`             | UDP (and/or TCP)                   |
| SIP over TLS   | `5061`             | TCP (only if your server uses TLS) |
| RTP (media)    | first ephemeral    | UDP — symmetric (same port both ways) |

> ✅ For a v1 setup behind one NAT, the simplest combo is **UDP/5060
> for SIP** and **one UDP port for RTP** (the client picks an ephemeral
> port at start; you'll see it in the Inbound tab once you fill in the
> Public RTP port and start listening). Forward both.

---

## Option 1 — Static port forwarding (router)

This is the canonical setup. Your router has a public IP; you tell it
"any UDP traffic that hits me on port X, send it to my Mac at port Y."

### Steps

1. **Reserve a LAN IP for your Mac.** In your router, set a DHCP
   reservation so the Mac always gets the same private IP (e.g.
   `192.168.1.42`). System Settings → Network shows the current one.

2. **Pick public ports** to expose. They can be the same as the local
   ports (clean) or different (if 5060 is taken by something else).
   Common picks:

   - `5060/udp` (public) → `5060/udp` on `192.168.1.42` (SIP)
   - `10000/udp` (public) → `10000/udp` on `192.168.1.42` (RTP)

3. **Add forwarding rules** in your router admin UI. The exact path
   varies by vendor — look for "Port Forwarding", "Virtual Server",
   "NAT". Each rule is *(public port, protocol, internal IP, internal port)*.

4. **In the SIP Client app, Inbound tab:**

   - Set **Local SIP port** to `5060` (matches the internal port
     above).
   - Set **Public host** to your router's public IPv4 (e.g. from
     `https://api.ipify.org`).
   - Set **Public SIP port** to whatever you forwarded (`5060` if you
     kept it the same).
   - Set **Public RTP port** to the public port you forwarded for
     RTP (`10000` in the example).
   - Click **Start**.

5. **Tell your SIP server** about that public address. For a LiveKit
   inbound trunk, set the destination URI to something like
   `sip:anything@<your-public-ip>:5060;transport=udp`. The server will
   send INVITEs there; your router translates them to your Mac.

### Notes / gotchas

- The Public RTP port the server sees has to be **the exact port the
  Mac is bound to** — not just "anywhere in 10000-20000". Forward one
  port, set that port as the RTP port, and you're done.
- If your ISP gives you a CGNAT (carrier-grade NAT) — common with
  cellular hotspots and some cable providers — you don't have a real
  public IP and port forwarding won't work. Use Option 2.
- macOS Firewall: System Settings → Network → Firewall. Either turn it
  off for testing or "Allow incoming connections" for the SipClient app.

---

## Option 2 — SSH reverse tunnel from a public VPS

If you already have a public Linux host you can SSH into (a $5/mo VPS,
a cloud sandbox, anything with a stable public IP), an `ssh -R` reverse
tunnel is a clean way to expose the SIP client without touching your
local router. The catch: OpenSSH only natively forwards **TCP**, not
UDP. SIP signaling can be TCP/TLS — RTP cannot — so the cleanest
practical setup is:

- **SIP signaling over TCP** through the SSH tunnel directly.
- **RTP (UDP)** forwarded via `socat` UDP↔TCP wrappers on both ends,
  carried over a second SSH tunnel.

### Prerequisites on the VPS

1. Install `socat`:

   ```bash
   sudo apt-get install -y socat        # Debian/Ubuntu
   sudo dnf install -y socat            # RHEL/Fedora
   ```

2. Allow the SSH daemon to bind reverse-forwarded ports to non-loopback
   addresses so external traffic reaches them. In `/etc/ssh/sshd_config`:

   ```
   GatewayPorts clientspecified
   ```

   Then `sudo systemctl reload ssh`. Without this, `ssh -R` only binds
   to `127.0.0.1` on the VPS and outside callers can't reach the tunnel.

3. Open the public ports in the VPS firewall (e.g. `ufw allow 5060/tcp`,
   `ufw allow 10000/udp`).

### Setup — SIP over TCP

In SipClient → Dialer / Inbound: use the **TCP** transport with local
SIP port `5060`.

On your Mac, start the tunnel:

```bash
ssh -N -R 0.0.0.0:5060:localhost:5060 user@vps.example.com
```

Configure your SIP server to send INVITEs to
`sip:anything@vps.example.com:5060;transport=tcp`. They'll travel:

```
SIP server → vps.example.com:5060/tcp → SSH tunnel → Mac:5060/tcp
```

In the Inbound tab fill in:

- **Public host:** `vps.example.com`
- **Public SIP port:** `5060`

### Setup — RTP over SSH (UDP wrapped in TCP via socat)

OpenSSH won't forward UDP, so we wrap RTP in TCP at each end using
`socat`. Pick a fixed RTP port for the client (we'll use `10000` here).

**On the VPS** (start before the SSH tunnel):

```bash
# Public-facing UDP listener that pipes into local TCP 10000
socat -T 600 UDP-LISTEN:10000,reuseaddr,fork TCP:127.0.0.1:10000 &
```

**On your Mac**, also start a `socat` to unwrap TCP back to the local
RTP UDP port:

```bash
socat -T 600 TCP-LISTEN:10000,reuseaddr,fork UDP:127.0.0.1:10000 &
```

**Then the SSH tunnel** (do both signaling and RTP at once):

```bash
ssh -N \
    -R 0.0.0.0:5060:localhost:5060 \
    -R 0.0.0.0:10000:localhost:10000 \
    user@vps.example.com
```

The full RTP flow:

```
peer → vps.example.com:10000/udp
     → socat (UDP→TCP) on vps:10000
     → SSH reverse tunnel (TCP)
     → socat (TCP→UDP) on Mac:10000
     → SipClient RTP socket
```

In the Inbound tab fill in:

- **Public host:** `vps.example.com`
- **Public SIP port:** `5060`
- **Public RTP port:** `10000`

The send direction is symmetric — outbound RTP from the Mac goes to
the peer's address directly (NAT keeps the return path open), or you
can mirror the wrapping if your peer is also locked down.

### Why not pure UDP via SSH?

It exists, but it's painful. Some shops use [`gost`](https://github.com/ginuerzh/gost)
or [`udp2raw`](https://github.com/wangyu-/udp2raw-tunnel) to forward
UDP through TCP-only paths; if you go that route, point them at the
RTP port and skip the `socat` step. Simpler still: a **WireGuard** link
between your Mac and the VPS gives you a real UDP-capable network that
the SIP client can use directly — set the Public host to your Mac's
WireGuard address and you don't need any wrappers at all. WireGuard is
usually the cleanest answer once you've already got a VPS.

---

## Option 3 — Tunnel service (ngrok)

Useful when you don't control the router (coffee shop, corporate
network, CGNAT, etc.). ngrok exposes a local UDP/TCP port through a
tunnel to a public hostname.

> ⚠️ **Free-tier ngrok rotates the public address every restart**, which
> means whatever you configure in the SIP server's trunk breaks every
> time you stop ngrok. For a stable setup you want a paid plan with
> reserved domains/addresses.

### Quick walkthrough

```bash
# Two terminal windows.
# 1) Tunnel SIP signaling — TCP works most reliably:
ngrok tcp 5060

# 2) Tunnel RTP — needs a UDP tunnel (paid feature):
ngrok udp 10000
```

ngrok prints a forwarding line like:

```
Forwarding   tcp://5.tcp.eu.ngrok.io:18234 -> localhost:5060
Forwarding   udp://6.tcp.eu.ngrok.io:23121 -> localhost:10000
```

In the Inbound tab:

- **Local SIP port:** `5060`
- **Public host:** `5.tcp.eu.ngrok.io`
- **Public SIP port:** `18234`
- **Public RTP port:** `23121` (and the public host for RTP would
  also be `6.tcp.eu.ngrok.io` if it differs from SIP — the v1 client
  reuses the SIP public host for RTP, so for ngrok the cleanest setup
  is to put your RTP host:port pair in the Public host / Public RTP
  port fields and accept that a single host serves both).

Configure your SIP server's outbound trunk to send INVITEs to
`sip:anything@5.tcp.eu.ngrok.io:18234;transport=tcp`.

---

## Sanity-checking from the public side

Once everything's running:

1. Use a SIP testing tool (`sipsak`, a softphone on a different network)
   or your SIP server's outbound test feature to send an OPTIONS or
   INVITE to the public address.
2. Watch the Wire Log in the Inbound tab. You should see `← INVITE`
   land. If nothing shows up, the firewall/NAT isn't forwarding —
   double-check the rules and that the listener is started.
3. After Answer, watch the **Δ inter-arrival** chart in the in-call
   panel. If RTP isn't reaching you, the chart stays empty — usually
   means the RTP UDP port isn't actually forwarded.

---

## Limitations of v1 inbound

- **UDP only** for the listener. TCP/TLS inbound is on the roadmap
  but not yet wired in (outbound TCP/TLS works fine).
- **No SRTP** on inbound calls (outbound supports SDES SRTP). The
  inbound 200 OK answer is plain `RTP/AVP` regardless of what the
  offer asks for; if the peer requires SRTP it'll reject.
- **No digest auth** on inbound. We accept any INVITE that reaches
  the listener and lets the user choose Answer / Reject.
- **One concurrent call.** A second INVITE while a call is active
  gets an automatic `486 Busy Here`.
