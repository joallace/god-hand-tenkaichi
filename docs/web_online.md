# Online play in the browser — initial notes

Status: **in progress** (decisions and design contract at the end). The
notes below were written first; "What exists today" describes the offline
web build before this work.

## What exists today

- **Offline web build.** `PlatformCaps` (`core/platform/platform_caps.gd`)
  says what the running platform can do. On web (`OS.has_feature("web")`):
  no window control, no Quit, no UPnP, no FSR, and
  `net_backend() == NetBackend.NONE`. `Net.online_available()` reads that,
  and every online entry hides behind it: the main menu's "Join online",
  the Settings Online tab, the lobby room button + Y/TAB/X/C keys, and the
  How to Play "Online" section. `Net.host()`/`join()` return
  `ERR_UNAVAILABLE`. `tests/web_platform_test` forces `PlatformCaps.web`
  and checks all of it.
- **Turning online on for web** comes down to: add a backend to
  `PlatformCaps.NetBackend`, return it from `net_backend()` on web, and make
  `Net.host()`/`join()` build that backend's transport. The menus come back
  on their own; then fix the screens that assume IP:port (below).
- **Verified (2026-10-29)**: the 4.7.2 `web_nothreads` template boots the
  game in Chrome (WebGL 2, Compatibility). `Net` still compiles there:
  `UPNP`, `ENetConnection`, `WebRTCPeerConnection`, `WebRTCMultiplayerPeer`
  and `WebSocketPeer` exist in the template. ENet just can't open a socket
  (browsers have no UDP).

## The core problem

A browser can only reach the network through HTTP(S), WebSocket (TCP) and
WebRTC. Of those, only **WebRTC data channels** give us what rollback needs:
an unreliable, unordered channel (inputs, acks, ping, hashes) next to
reliable ordered ones (lobby, commands, bulk). A WebSocket relay would
work, but over TCP: one lost packet holds up every input behind it, which
is exactly what rollback is meant to hide. Use it only as a last-resort
fallback, if at all.

So the job is a `WebRtcTransport extends Transport`, plus what WebRTC needs
around it:

1. **Signaling server.** Before two WebRTC peers can talk, they swap SDP
   offers/answers and ICE candidates through some other channel, usually a
   small WebSocket server. It also becomes the room directory: host gets a
   short room code, guests join by code. Godot's demo projects include a
   WebRTC signaling server (Node or GDScript); it's a reference only, we
   write our own.
2. **STUN** (public servers are fine to start with) so peers learn their
   public address for hole punching.
3. **TURN** (relay) for the peers hole punching can't connect (symmetric
   NAT, CGNAT, mobile networks): roughly 10–20% of real pairs. That means
   running coturn somewhere, or paying for a hosted TURN service. Without
   TURN, some friends simply can't play together.

This overlaps with SPEC_ONLINE.md §15 milestone 6 ("rendezvous/relay
server + room codes"), which planned a noray-style **UDP** hole-punch +
relay. Browsers can't use that. If web online is wanted, WebRTC is probably
the right choice for milestone 6 on **every** platform (one NAT-traversal
stack, cross-play for free), with direct-IP ENet kept as the
LAN / port-forwarded option on desktop. That's a decision for the user;
see open questions.

## Mapping onto the existing net stack

`Transport` (core/net/transport.gd) is already the right seam: peer-id
links, three channels, `poll()` events, `send`/`flush`/`disconnect_peer`/
`close`. Session, Protocol, InputHistory, TimeSync and RollbackDriver sit on
top and shouldn't need changes.

- **Channels → data channels** (one `WebRTCPeerConnection` per link,
  negotiated channels with fixed ids so both sides agree without extra
  signaling):
  - `UNRELIABLE` → `ordered = false, maxRetransmits = 0`
  - `RELIABLE` → ordered, reliable
  - `BULK` → ordered, reliable, a separate channel so a snapshot doesn't
    block lobby/commands (same reason ENet has channel 2)
- **Topology**: keep the host-relayed star (SPEC_ONLINE.md §5.2). Each guest
  has one connection, to the host; the host has one per guest. Peer ids keep
  the `Transport` rules (host = 1, guests = lowest free id ≥ 2). The
  signaling server only brokers the connections; it never carries game
  packets.
- **Either raw `WebRTCPeerConnection`s or `WebRTCMultiplayerPeer`.** We
  don't use MultiplayerAPI/@rpc anywhere (EnetTransport uses a raw
  ENetConnection for the same reason), so raw connections + data channels
  fit the existing pattern best. Polling: `WebRTCPeerConnection.poll()` and
  each `WebRTCDataChannel.poll()` every `Transport.poll()`.
- **Connection lifecycle**: CONNECTED only once all three channels are open
  (ENet's CONNECTED means the same thing). Report ICE failure / closed
  connections as DISCONNECTED. A timeout for "signaling ok but ICE never
  connects" must surface as a join failure with useful text ("Could not
  reach host, a relay may be needed").
- **Message sizes**: SCTP messages above ~16 KB are unsafe across browsers.
  Bulk snapshots (zstd'd `var_to_bytes`) can be larger, so the transport
  (or Protocol's bulk path) needs to chunk + reassemble. Check what the
  largest bulk message really is first (RESYNC snapshot with a full co-op
  field). Measured (tests/net_webrtc_session_test INFO line): ~3.4 KB on
  the wire at the online field cap of 6 (24 KB raw before zstd), ~5.3 KB
  at 16 fighters; MATCH_START ~1 KB. WebRtcTransport chunks anyway.
- **Stats**: `net_overlay` asks the transport for `packet_loss(peer)`
  through `has_method`. WebRTC exposes stats only in a limited way through
  Godot; leaving it out is fine (the overlay copes). RTT already comes from
  Session's own PING/PONG.
- **Tests**: `LoopbackTransport` keeps covering Session/rollback logic. For
  the WebRTC transport, a headless test with two in-process peers connected
  through an in-process "signaling" (pass SDP/ICE directly) proves the
  channel mapping. That needs the WebRTC implementation on desktop too (next
  section).

## Desktop side and cross-play

- Godot desktop builds **don't include** a WebRTC implementation; it comes
  from the `webrtc-native` GDExtension (godotengine/webrtc-native). Needed
  for desktop ↔ browser play and for headless tests of the transport.
- The web export template doesn't load GDExtensions in the `nothreads`
  variant without `variant/extensions_support=true`, but the browser has
  WebRTC built in, so the web build doesn't need the extension at all.
- Cross-play also needs **cross-runtime determinism**: WASM vs native
  x86_64. IEEE floats behave the same, and DetMath keeps libm out of the
  sim, but engine internals compiled by a different compiler (Emscripten's
  libc/libm for anything Godot calls internally, e.g. inside `Vector3`
  methods or physics) can still differ. Check with a replay:
  `tools/replay_hash.tscn -- record=...` on desktop, then play it back in
  the browser and compare hashes. That needs a small web-only path to load
  a replay and print hashes (e.g. a URL query flag read through
  `JavaScriptBridge`, or bundling a test replay in a debug export). Do this
  **first**: if hashes differ, cross-play is off until it's fixed, whatever
  the transport does.
- `ContentHash` and the HELLO version checks already reject mismatched
  builds; web and desktop builds from the same commit should agree. Verify
  that too, since export may strip or remap resources differently.

## Performance in the browser

GDScript in WASM runs slower than native (expect around 1.5–3× slower,
measure it). Rollback re-simulates up to `max_rollback_frames` ticks in one
frame; SPEC_ONLINE.md §12 gives an 8 ms budget, and the desktop p95 is
already ~5–6 ms at 6 fighters. Likely consequences:

- Run `tools/net_bench` logic in the browser (another web-only debug entry
  point) to get real numbers.
- A lower `coop.online_field_cap` and/or `max_rollback_frames` for any
  session with a browser peer. The host knows each peer's platform if HELLO
  carries it: add a `platform` field to HELLO and pick caps from it, which
  keeps the sim the same for everyone (caps are match config, not code
  branches).
- The browser main loop runs on `requestAnimationFrame`; background tabs
  get throttled to ~1 Hz or paused. A peer whose tab goes to the background
  will stall the session and then time out. Detect it
  (`NOTIFICATION_APPLICATION_FOCUS_OUT` / visibility) and at least show a
  warning; a reconnect / CPU takeover (§13) is the real answer.
- Single-threaded build: no worker threads, so everything (sim, rollback,
  rendering, audio mixing) shares one thread. The threaded web template
  needs cross-origin isolation headers (COOP/COEP) from the host server;
  look into it only if the bench says so.

## UI that assumes IP:port

These go through `Net.online_available()` today and will reappear on web as
soon as a backend exists; each needs a room-code path:

- `scenes/menus/join_online_screen.gd`: address field parsed with
  `EnetTransport.parse_address`; recent hosts store addresses
  (`OnlineSettings.recent_hosts`). On web: a room-code field; recent rooms
  maybe, codes probably expire.
- `scenes/menus/lobby.gd` `_refresh_room` / `_host_addresses` /
  `copy_address`: LAN IPs, UPnP status, "forward UDP port" hint. On web: show
  and copy the room code (or a join URL like `…/index.html?room=ABCD` that
  the page reads through `JavaScriptBridge`, the nicest way to invite
  friends in a browser). `DisplayServer.clipboard_set` works on web but
  only from a user gesture; it's called from a button/key handler, so
  probably fine, but verify.
- `scenes/menus/settings/online_page.gd`: host port row means nothing for
  WebRTC; hide it when the backend isn't ENet.
- `ui/how_to_play_panel.gd` ONLINE_LINES talk about UDP ports and UPnP.
- `Net.host(port)` / `Net.join(address)` signatures are ENet-shaped. A
  clean way: `Net.host()` with no args returns at once and the room code
  arrives by signal (signaling is async), `Net.join(code_or_address)`
  lets the backend parse it.
- Results "Save replay" (online only) writes to `user://` (IndexedDB) and
  shows a path the player can't open. On web, offer a download instead
  (`JavaScriptBridge.download_buffer`).

## Suggested order

1. Cross-runtime determinism check (replay hashes desktop vs browser).
2. Signaling server (small, separate repo or `server/` dir; WebSocket, room
   codes, rate limits, no game logic) + a local dev setup.
3. `WebRtcTransport` on desktop with webrtc-native; headless two-peer test.
4. Browser peer ↔ desktop peer through the real signaling server on
   localhost; then over the internet with STUN; then TURN.
5. Room-code UI; `PlatformCaps.net_backend()` returns WEBRTC on web.
6. Browser perf caps (HELLO platform field), background-tab handling.
7. Hosting: static files for the game (itch.io / GitHub Pages / Cloudflare
   Pages), plus the signaling server and TURN somewhere always-on.

## Decisions (2026-10-30)

- **WebRTC + room codes is the milestone-6 stack on every platform.**
  Desktop gets WebRTC from the vendored `addons/webrtc_native` (webrtc-native
  1.2.2, Linux/Windows x86_64; `exclude_tags = ["web"]`, the browser has its
  own). Direct-IP ENet stays on desktop for LAN / port-forwarded play.
- **Cross-play** desktop ↔ browser, gated on the cross-runtime replay hash
  check. If hashes differ, rooms reject mixed platforms until fixed.
- **Signaling server: Python** (asyncio + `websockets`) in `server/`.
- **TURN: coturn shipped, opt-in** (`docker compose --profile turn`). The
  signaling server hands out ICE servers from its own config, with
  time-limited TURN credentials (TURN REST scheme, coturn
  `use-auth-secret`); no TURN secret ever ships in the game.
- Game hosting is still open (itch.io / Pages / own domain): the join URL
  is built from the page's own location, so it works anywhere.

## Design contract

### Signaling protocol (v1)

JSON text frames over one WebSocket per client (`ws://` dev, `wss://`
deployed). Every message is an object with an `"op"` string. The server
only brokers WebRTC connections and the room directory; it never carries
game packets and holds no game logic.

Client → server:

| op | fields | reply |
|---|---|---|
| `host` | `game` (opaque build id string), `max_guests` (int ≥ 1) | `hosted` {`room`, `peer`: 1, `ice_servers`} |
| `join` | `room` (code, case-insensitive), `game` | `joined` {`room`, `peer`: sid, `ice_servers`}; the host gets `peer_joined` {`peer`: sid} |
| `signal` | `to` (sid), `data` (object, opaque to the server) | relayed to `to` as `signal` {`from`: sid, `data`} |
| `ping` | — | `pong` |

Server → client, unsolicited: `peer_joined` {`peer`}, `peer_left` {`peer`}
(guest's socket closed; a guest whose WebRTC link is already up may leave
signaling, so the host transport ignores this for connected links),
`room_closed` (host's socket closed; sent to guests still on signaling),
`error` {`code`, `message`}.

- **sids** are routing ids inside one room: host = 1, guests 2, 3, … in
  join order, never reused within a room. They are *not* Transport link
  ids; the host's transport maps sid → link id itself.
- A guest may only `signal` sid 1; the host may signal any guest sid in its
  room. Anything else → `error` `bad_request`.
- `game` must match the host's exactly, or `error` `version_mismatch`.
  The client sends `"%d:%s" % [Protocol.VERSION, ContentHash.compute()]`
  so mismatched builds are refused before any WebRTC work.
- **Error codes**: `bad_request`, `room_not_found`, `room_full`,
  `version_mismatch`, `rate_limited`, `server_full`, `already_in_room`.
  After an error on `host`/`join` the server closes the socket.
- **Room codes**: 6 chars from `ABCDEFGHJKLMNPQRSTUVWXYZ23456789` (no
  0/O/1/I), matched case-insensitively, alive while the host's socket is
  open (plus a max room lifetime).
- `signal.data` shapes (the server doesn't look inside): `{"type":
  "offer"|"answer", "sdp": String}` and `{"type": "candidate", "mid":
  String, "index": int, "sdp": String}`.
- `ice_servers`: a WebRTC `iceServers` array: `[{"urls": [...]},
  {"urls": [...], "username": "<expiry unix>:<label>", "credential":
  base64(HMAC-SHA1(secret, username))}]`.
- Limits (configurable): message size, messages/s per socket, sockets and
  rooms per IP, total rooms, an idle timeout for a socket that never
  hosts/joins, and keepalive.

### WebRtcTransport (`core/net/webrtc_transport.gd`)

`extends Transport`, same events and peer-id rules as `EnetTransport`:

- `host_room(signaling: SignalingClient, game_id: String, max_guests: int) -> Error`
  and `join_room(signaling: SignalingClient, code: String, game_id: String) -> Error`.
  `SignalingClient` (`core/net/signaling_client.gd`) is the WebSocket
  client; it extends a small base whose in-process twin
  (`LocalSignaling`, tests) needs no server.
- Signals: `room_opened(code: String)` (host), `signaling_error(code:
  String, text: String)` (user-facing text), `signaling_lost()` (host:
  socket dropped, so no new joins; existing links keep playing).
  `room_code()`; `last_error_text()`.
- Host offers; one `WebRTCPeerConnection` per link; negotiated data
  channels with fixed ids: 0 = UNRELIABLE (`ordered: false,
  maxRetransmits: 0`), 1 = RELIABLE, 2 = BULK (both ordered, reliable).
- CONNECTED once all three channels are open. ICE failure / closed → 
  DISCONNECTED. A guest that never connects within
  `Tuning.net.webrtc_connect_timeout_frames` gets DISCONNECTED for
  HOST_PEER with `last_error_text()` "Could not reach the host (a TURN
  relay may be needed)". Signaling errors before connecting do the same
  with the error's text.
- RELIABLE/BULK messages are chunked (`Tuning.net.webrtc_chunk_bytes`,
  ≤ 16 KB) and reassembled; UNRELIABLE is sent whole (Protocol keeps it
  under `max_packet_bytes`).
- The guest closes its signaling socket once connected; the host keeps
  its socket for the room's lifetime (new guests).

### Net / PlatformCaps

- `PlatformCaps.NetBackend { NONE, ENET, WEBRTC }`; `direct_ip()` (ENet:
  desktop), `room_codes()` (WebRTC class usable: web, or the extension
  loaded), `online()` = either.
- `Net.host_room() -> Error` (async; `room_code_changed(code)` signal,
  `Net.room_code`), `Net.host(port)` stays direct-IP ENet,
  `Net.join(text)`: a room code (or a join URL holding `room=`) →
  WebRTC, otherwise an ENet address (desktop only).
- Signaling URL: `OnlineSettings.signaling_url` override; empty = the
  default: on web, the page's own host on `Tuning.net.signaling_port`
  (`wss` when the page is https); on desktop `Tuning.net.signaling_url`.
  A `?signal=` page query overrides it on web.
- Web join links: `<page url>?room=CODE`; the page reads `room` at boot
  (`JavaScriptBridge`) and goes to the join flow.

## Open questions

- Where will the game and the servers be hosted? (Defaults above work
  anywhere; deploy steps in `server/README.md`.)
