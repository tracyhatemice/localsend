# Deploying coturn via apt with TURNS (Let's Encrypt IP cert)

This is an alternative to running coturn in the docker-compose stack. Useful
when you'd rather have coturn managed by systemd directly on the host, or
when you want to terminate TURN-over-TLS (`turns://`) for clients that
can't use plain `turn://` (e.g. browsers behind aggressive corporate
firewalls).

## When to choose this over docker

- You want TURNS (TURN-over-TLS, port 5349).
- You want coturn to use the host's actual public IPs without
  `network_mode: host` Docker pitfalls.
- You're comfortable managing certs and systemd directly.

If none of those apply, the docker-compose service in
[compose.example.yaml](../compose.example.yaml) is the simpler path.

## Prerequisites

- Debian/Ubuntu host with public IPv4 and IPv6.
- Ports open at the firewall (both v4 and v6):
  - UDP+TCP **3478** (STUN/TURN plain)
  - UDP+TCP **5349** (TURNS, TURN over TLS)
  - UDP **49160-49200** (relay range — keep tight so the firewall rule stays manageable)
- The signaling server (the rust service in this repo) reachable on a
  domain or IP. It uses `TURN_AUTH_SECRET` to mint HMAC-time-limited
  credentials, which coturn validates using the same secret.

## Step 1 — Install

```bash
sudo apt update
sudo apt install -y coturn certbot
```

Enable coturn at boot:

```bash
sudo sed -i 's/^#TURNSERVER_ENABLED=1/TURNSERVER_ENABLED=1/' /etc/default/coturn
```

## Step 2 — Acquire a TLS cert for the IP

Let's Encrypt began issuing short-lived (≤6 day) IP-address certificates in
2025. Certbot supports them through the `shortlived` ACME profile.

> Double-check the exact flag in the current certbot docs — the option name
> has churned. As of writing, the canonical incantation is below.

```bash
sudo certbot certonly \
  --standalone \
  --preferred-profile shortlived \
  --agree-tos \
  --email you@example.com \
  -d "$(curl -s https://ifconfig.me)"
```

Replace the `-d` value with your actual public IPv4 if `ifconfig.me`
doesn't match what you want clients to dial. For IPv6, add a second
`-d <v6-address>` — coturn binds to both stacks.

Cert will land at `/etc/letsencrypt/live/<ip>/{fullchain,privkey}.pem`.
Certbot's systemd timer (installed by the package) handles renewal.

### Renewal hook to reload coturn

Add this so coturn picks up renewed certs without manual intervention:

```bash
sudo tee /etc/letsencrypt/renewal-hooks/deploy/reload-coturn.sh <<'EOF'
#!/bin/sh
systemctl reload coturn
EOF
sudo chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-coturn.sh
```

### Fallback: use a domain cert instead of an IP cert

If LE's IP-cert flow doesn't work in your environment, point a domain at
the same IP (e.g. `turn.example.org`) and use the standard `--standalone -d
turn.example.org` flow. Everything else in this doc stays the same; just
substitute the path under `/etc/letsencrypt/live/turn.example.org/`.

The web client doesn't care — coturn returns the same `RTCIceServer` to
WebRTC regardless of how the cert was issued.

## Step 3 — Configure coturn

Reference to `turnserver.example.conf` and edit `/etc/turnserver.conf` (or wherever your distro puts it). Note key settings: 

```ini
# Auth: HMAC time-limited credentials (must match TURN_AUTH_SECRET in
# the signaling server's .env).
use-auth-secret
static-auth-secret=REPLACE_ME_WITH_TURN_AUTH_SECRET
realm=REPLACE_ME_WITH_YOUR_FQDN_OR_IP

fingerprint

# Ports.
listening-port=3478
tls-listening-port=5349

# Relay port range. Must be open on your firewall (UDP).
min-port=49160
max-port=49200

# TLS cert (substitute the actual path under /etc/letsencrypt/live/...).
cert=/etc/letsencrypt/live/REPLACE_ME/fullchain.pem
pkey=/etc/letsencrypt/live/REPLACE_ME/privkey.pem
# Modern-only ciphers.
no-tlsv1
no-tlsv1_1
no-tlsv1_2

# Rate limits — the signaling endpoint that mints HMAC creds is
# unauthenticated, so anyone who can hit /v1/turn-creds can ask for
# credentials. Cap the blast radius if that happens.
total-quota=100
user-quota=10
max-bps=10000000

# Safety.
no-multicast-peers
no-loopback-peers
no-cli
no-tcp-relay

# Optional: prevent TURN from relaying into your private LAN. Skip if you
# need same-LAN dual-stack peers to use TURN.
#
# denied-peer-ip=10.0.0.0-10.255.255.255
# denied-peer-ip=172.16.0.0-172.31.255.255
# denied-peer-ip=192.168.0.0-192.168.255.255
# denied-peer-ip=fd00::-fdff:ffff:ffff:ffff:ffff:ffff:ffff:ffff

# Logging — coturn defaults are noisy; tune as desired.
# log-file=/var/log/coturn/turnserver.log
syslog
simple-log

no-software-attribute
```

## Step 4 — Start & verify

```bash
sudo systemctl enable --now coturn
sudo systemctl status coturn   # expect: active (running)
sudo journalctl -u coturn -n 30 --no-pager
```

You should see lines like:

```
0: : Bind address = 0.0.0.0:3478
0: : Bind address = ::
0: : TLS listener address = ...:5349
0: : TURN Server
```

Test from another host (replace `<ip>` and `<port>`):

```bash
# Plain STUN binding (no auth)
stunclient <ip> 3478

# TLS reachability
echo Q | openssl s_client -connect <ip>:5349 -quiet
```

## Step 5 — Point the signaling server at this coturn

In your localsend `.env`:

```bash
# coturn serves STUN on the plain port (3478) regardless of TURNS config.
STUN_URL=stun:<ip>:3478
# Use turns: instead of turn: to advertise the TLS endpoint to clients.
TURN_URL=turns:<ip>:5349
TURN_AUTH_SECRET=<same value you put in static-auth-secret above>
```

Restart the signaling service (`docker compose restart localsend-signaling`)
so it picks up the new env. The web client now receives `turns://` ICE
candidates and uses TURN-over-TLS.

You can also list both `turn:` and `turns:` if you want clients to pick
whichever works. The TURN_URL field currently accepts a single string;
plumb it through as an array if you need multiple.

## Step 6 — Trust the cert chain

WebRTC validates the TURN server's cert like any TLS connection. If
clients see `OnIceConnectionStateChange: failed` and `webrtc-internals`
shows `srflx/relay` candidates from your TURN host with type "failed", the
cert is the most likely culprit. Test:

```bash
openssl s_client -connect <ip>:5349 -servername <ip> </dev/null 2>&1 | grep -E 'Verify return|subject='
```

`Verify return: 0 (ok)` and a `subject=` line matching the IP/host you're
dialing means the cert is good.

## Migration from the docker-compose coturn

If you started with the docker coturn service and want to switch to apt:

1. Stop and remove the docker service: `docker compose rm -sf coturn`.
2. Do steps 1–4 above.
3. The signaling server's `TURN_AUTH_SECRET` value carries over unchanged
   — just make sure you copy the same value into the apt coturn's
   `static-auth-secret`.
4. Update `TURN_URL` in `.env` to point at the apt coturn (use `turns://`
   if you set up TLS).
