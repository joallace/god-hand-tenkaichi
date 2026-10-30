# Signaling server (and optional TURN relay)

Online play over WebRTC (browser builds, and desktop through the vendored
webrtc-native addon) needs a small rendezvous service. `signaling_server.py`
is that service; protocol v1 is specified in `docs/web_online.md`
("Design contract → Signaling protocol").

What it does:

- Hands out 6-character room codes (`ABCDEFGHJKLMNPQRSTUVWXYZ23456789`,
  case-insensitive). A room lives while its host's WebSocket is open, up to
  a max lifetime.
- Relays opaque `signal` messages (SDP offers/answers, ICE candidates)
  between the host (sid 1) and its guests (sids 2, 3, … never reused).
- Refuses a join from a different build (`game` string must match exactly).
- Gives each client the ICE server list: STUN URLs and, when TURN is set up,
  time-limited TURN credentials.

What it does not do: it never carries game packets (those go peer to peer,
or through TURN), holds no game logic, stores nothing on disk, and does not
authenticate players. Once a guest's WebRTC link is up it may leave
signaling; the match keeps running if this server restarts (only new joins
fail).

Python 3.10+, one dependency (`websockets`; works with 12.x and the pinned
version in `requirements.txt`).

## Local development

```sh
pip install -r server/requirements.txt     # or your distro's python3-websockets
python3 server/signaling_server.py         # ws://0.0.0.0:8765
python3 -m unittest server/test_signaling_server.py
```

`curl http://localhost:8765/healthz` prints `ok`.

### On the LAN (phones, a second PC)

```sh
python3 tools/serve_web.py     # https://<LAN IP>:8443/, signaling on /signal
```

A page served over HTTPS can only open `wss://` sockets, and a browser
never shows the "accept this certificate" prompt for a WebSocket: a
self-signed `wss://<LAN IP>:8765` fails silently ("Could not reach the
signaling server") until that host:port was opened as a page and accepted.
So `tools/serve_web.py` also forwards WebSocket upgrades on `/signal` to a
signaling server on port 8765 (it reuses one already running there, else
starts one), and the web build's default signaling URL is its own origin +
`/signal` (`Tuning.net.signaling_path`): the certificate accepted for the
page covers it.

Desktop builds on another machine use the server directly: Settings >
Online > Signaling server = `ws://<LAN IP>:8765` (serve_web.py prints it;
debug builds default to `ws://127.0.0.1:8765`, which only works on the
machine running the server).

`--dev-cert` (`wss://` straight on 8765 with `builds/web-cert/`) still
works, but then each device must also open `https://<LAN IP>:8765/healthz`
once and accept the warning.

## Settings

Every setting has a default, an env var and a CLI flag (CLI beats env beats
default). `--help` prints them all with their current values. Lists are
comma-separated; booleans take `1/0/true/false/yes/no`.

| Flag | Env | Default | Meaning |
|---|---|---|---|
| `--bind` | `GHT_SIGNAL_BIND` | `0.0.0.0` | listen address |
| `--port` | `GHT_SIGNAL_PORT` | `8765` | listen port |
| `--cert`, `--key` | `GHT_SIGNAL_CERT`, `GHT_SIGNAL_KEY` | — | PEM files for `wss://` |
| `--dev-cert` | `GHT_SIGNAL_DEV_CERT` | off | use `builds/web-cert/` |
| `--trust-proxy` | `GHT_SIGNAL_TRUST_PROXY` | off | client IP = last `X-Forwarded-For` hop |
| `--healthz` | `GHT_SIGNAL_HEALTHZ` | on | `GET /healthz` → 200 |
| `--log-level` | `GHT_SIGNAL_LOG_LEVEL` | `INFO` | |
| `--max-message-bytes` | `GHT_SIGNAL_MAX_MESSAGE_BYTES` | `16384` | larger frames close the socket (1009) |
| `--msg-rate` | `GHT_SIGNAL_MSG_RATE` | `20` | messages/s refilled per socket |
| `--msg-burst` | `GHT_SIGNAL_MSG_BURST` | `80` | token bucket size per socket |
| `--max-sockets` | `GHT_SIGNAL_MAX_SOCKETS` | `4000` | whole server (`server_full`) |
| `--max-sockets-per-ip` | `GHT_SIGNAL_MAX_SOCKETS_PER_IP` | `16` | (`rate_limited`) |
| `--max-rooms` | `GHT_SIGNAL_MAX_ROOMS` | `1000` | whole server (`server_full`) |
| `--max-rooms-per-ip` | `GHT_SIGNAL_MAX_ROOMS_PER_IP` | `4` | (`rate_limited`) |
| `--max-guests-cap` | `GHT_SIGNAL_MAX_GUESTS_CAP` | `7` | highest `max_guests` a host may ask |
| `--idle-timeout` | `GHT_SIGNAL_IDLE_TIMEOUT` | `30` s | socket that never hosts/joins is closed (4001) |
| `--room-lifetime` | `GHT_SIGNAL_ROOM_LIFETIME` | `21600` s | room closed after this (4002) |
| `--sweep-interval` | `GHT_SIGNAL_SWEEP_INTERVAL` | `1` s | idle/lifetime check period |
| `--ping-interval` | `GHT_SIGNAL_PING_INTERVAL` | `20` s | WebSocket keepalive (0 = off) |
| `--ping-timeout` | `GHT_SIGNAL_PING_TIMEOUT` | `20` s | drop a socket that misses a pong |
| `--stun-urls` | `GHT_STUN_URLS` | `stun:stun.l.google.com:19302` | empty = none |
| `--turn-urls` | `GHT_TURN_URLS` | — | e.g. `turn:turn.example.com:3478?transport=udp` |
| `--turn-secret` | `GHT_TURN_SECRET` | — | coturn `static-auth-secret` |
| `--turn-secret-file` | `GHT_TURN_SECRET_FILE` | — | read the secret from a file |
| `--turn-ttl` | `GHT_TURN_TTL` | `21600` s | credential lifetime |

Server behavior beyond the contract table: an error on `host`/`join` closes
the socket (1000); a rate-limit hit sends `rate_limited` and closes (1008);
a host `signal` to a guest that already left signaling is dropped quietly
(late ICE candidates are normal), to a sid never issued it is `bad_request`;
when a room hits its lifetime the host also gets `room_closed`.

Logs are `key=value` lines (room created/closed, joins/leaves, rejects,
rate-limit hits). SDP and candidates are never logged.

## Deploying on a VPS (docker compose)

Any small VPS works: signaling is a few KB per match.

```sh
cd server
cp .env.example .env          # edit it
docker compose up -d --build                  # signaling only
docker compose logs -f signaling
```

Open TCP 8765 in the firewall (or whatever `GHT_SIGNAL_PUBLISH` says).

### TLS (needed: an HTTPS game page can only use `wss://`)

Two options:

1. **Reverse proxy** (Caddy, nginx) on 443 terminating TLS and proxying
   WebSocket upgrades to `127.0.0.1:8765`; set `GHT_SIGNAL_TRUST_PROXY=1` so
   per-IP limits see real client IPs (only when the proxy sets
   `X-Forwarded-For` and port 8765 is not reachable from outside). Then the
   game's signaling URL is `wss://signal.example.com/`. If the same host also
   serves the web build, proxy `/signal` there instead and the web build
   needs no URL at all (its default is the page's origin + `/signal`), e.g.
   Caddy: `handle /signal { reverse_proxy 127.0.0.1:8765 }`; nginx:
   `location /signal { proxy_pass http://127.0.0.1:8765; proxy_http_version 1.1;
   proxy_set_header Upgrade $http_upgrade; proxy_set_header Connection "upgrade";
   proxy_set_header X-Forwarded-For $remote_addr; }`. Game page elsewhere
   (itch.io): set `Tuning.net.web_signaling_url` (and `signaling_url` for
   desktop) to the server's `wss://` URL.
2. **Direct**: get a certificate with certbot
   (`certbot certonly --standalone -d signal.example.com`), copy it into
   `server/certs/` with a deploy hook (Let's Encrypt's `live/` files are
   symlinks that do not survive a bind mount):

   ```sh
   # /etc/letsencrypt/renewal-hooks/deploy/ght.sh
   install -m 0644 "$RENEWED_LINEAGE/fullchain.pem" /opt/ght/server/certs/fullchain.pem
   install -m 0644 "$RENEWED_LINEAGE/privkey.pem"   /opt/ght/server/certs/privkey.pem
   cd /opt/ght/server && docker compose restart
   ```

   (the containers run as non-root users, hence 0644 on a single-tenant
   box), then set `GHT_SIGNAL_CERT=/certs/fullchain.pem`,
   `GHT_SIGNAL_KEY=/certs/privkey.pem`. coturn reads the same directory.

### Enabling TURN (coturn)

Without TURN, players behind symmetric NAT / strict firewalls (some mobile
carriers, corporate and campus networks) cannot connect; the game then says
"Could not reach the host (a TURN relay may be needed)".

1. DNS: an A (and AAAA if you have IPv6) record, e.g. `turn.example.com`.
2. In `.env`:
   - `GHT_TURN_SECRET=$(openssl rand -hex 32)` (coturn refuses to start
     with an empty, short or `change-me` secret);
   - `GHT_TURN_REALM=turn.example.com`;
   - `GHT_TURN_URLS=turn:turn.example.com:3478?transport=udp,turn:turn.example.com:3478?transport=tcp,turns:turn.example.com:5349?transport=tcp`
     (drop the `turns:` entry if you have no certificate);
   - `GHT_TURN_EXTERNAL_IP` if the VPS is behind 1:1 NAT (AWS, GCP);
     otherwise the image looks it up.
3. Firewall: UDP+TCP 3478, TCP (and UDP) 5349, and the relay range UDP
   `GHT_TURN_MIN_PORT`–`GHT_TURN_MAX_PORT` (default 49160–49200, about 20
   concurrent relayed players; widen for more).
4. `docker compose --profile turn up -d --build`. coturn uses host
   networking (the relay range would otherwise need one published port
   each). `turnserver.conf` holds the static hardening: `use-auth-secret`,
   `fingerprint`, `no-tcp-relay`, `no-multicast-peers`, denied private /
   loopback / link-local / CGNAT peer ranges (the relay cannot reach the
   VPS's private network or cloud metadata), quotas and a per-session
   bandwidth cap. TLS on 443 (for networks that block everything else) is
   possible with `alt-tls-listening-port=443` when nothing else uses 443.

How credentials work (TURN REST / coturn `use-auth-secret`): the signaling
server and coturn share `GHT_TURN_SECRET`. For each `hosted`/`joined` the
server builds `username = "<unix expiry>:<room>-<sid>"` and
`credential = base64(HMAC-SHA1(secret, username))`; coturn recomputes the
HMAC and rejects expired usernames. The secret never leaves the servers
and nothing secret ships in the game; a leaked credential is only good
until its expiry (`GHT_TURN_TTL`, default 6 h, about one room lifetime).

Verifying TURN: take the `ice_servers` from a `hosted` reply (e.g. with
`python3 -m websockets wss://signal.example.com/`, then type
`{"op":"host","game":"x","max_guests":1}`), paste the TURN URL, username and
credential into the WebRTC "Trickle ICE" sample page
(webrtc.github.io/samples/src/content/peerconnection/trickle-ice/), and
"Gather candidates": a working relay shows candidates of type `relay`
(an auth problem shows error 401, an unreachable port shows none).

Cost: STUN is free and tiny; relayed traffic goes through your VPS twice
(in and out) and counts against its bandwidth bill. A relayed 1v1 is
roughly 10–30 KB/s each way; most players never need the relay, but watch
the provider's traffic graph after enabling it. `max-bps`, `user-quota`
and `total-quota` in `turnserver.conf` cap the worst case.

## Rate-limit tuning

- A normal connection sends `host`/`join`, one offer or answer and a burst
  of 5–20 ICE candidates per link, then `ping`s. A host with 3 guests sends
  the most; `msg_burst=80` with `msg_rate=20` leaves room for that. If hosts
  of big rooms get `rate_limited`, raise `GHT_SIGNAL_MSG_BURST` first.
- `max_sockets_per_ip` / `max_rooms_per_ip` must allow several players
  behind one NAT (a LAN party, a dorm, carrier-grade NAT): keep them well
  above 2. Behind a proxy without `--trust-proxy` every client shares the
  proxy's IP, so those limits would hit everyone at once.
- `idle_timeout` only applies before host/join; raise it if clients on slow
  links get closed while the menu is still loading.
- `max_message_bytes` 16 KB fits any SDP the game makes (1–4 KB).
