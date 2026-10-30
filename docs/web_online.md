# Online play in the browser — initial notes

Status: **implemented** (2026-10-30): WebRTC room codes on web and desktop,
cross-play, `server/` signaling + opt-in coturn; tested headless and
Chrome <-> desktop on one machine (`tools/crossplay_e2e.py`), not yet over a
real LAN/WAN or TURN. Decisions and the design contract are at the end; the
notes below were written first ("What exists today" = the offline build).

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
- **Verified (2026-10-30): cross-runtime determinism OK.** Five CPU-only
  replays recorded on desktop (editor binary, Linux x86_64) are bundled in
  `tools/replays/` and replayed in Chrome 150 (WASM, `web_nothreads`
  release) by `tools/web_tools.sh tool=replay`: every checkpoint hash
  (every 30 ticks) matches, and so does the Linux release template.
  `versus_1v1` (3600 ticks), `versus_ffa4` (4 fighters, 3600),
  `coop_waves` (3600), `coop_3p_brawl8` (3 humans + 5 enemies, 8 on the
  field, 4800), `coop_4p_brawl8` (4 + 4, 3600): 0 of 640 checkpoints differ.
  The exported web build's `ContentHash` equals the desktop one (replays
  carry it; no mismatch warning). Re-record after any sim change
  (`tools/replay_hash.tscn -- record=res://tools/replays/<name>.ghr ...`,
  args in its header) and rerun before trusting cross-play.
- HELLO carries `platform` ("desktop" / "web", `PlatformCaps.platform_name()`;
  Protocol 3). The host keeps it per peer (`Session.peer_platform(peer)`,
  `includes_platform()`; WELCOME / PEERS share every member's) and, when
  `Tuning.net.cross_play` is off, rejects a guest of the other platform
  with `Protocol.Reason.PLATFORM` ("Cross-play unavailable (host: desktop,
  you: web)"). On by default, since the hashes agree.

## Cross-play end-to-end check

`tools/crossplay_e2e.sh` (Python: `tools/crossplay_e2e.py`, needs python3
+ websockets and google-chrome) plays real desktop ↔ browser matches:

```sh
tools/crossplay_e2e.sh                          # versus, both directions, 1800 ticks
tools/crossplay_e2e.sh --mode versus,coop --delay 0
tools/crossplay_e2e.sh --pairs desktop:web --no-export   # host:guest; reuse builds/web-tools/
```

It starts `server/signaling_server.py` on 127.0.0.1:18765, exports "Web
Tools" to `builds/web-tools/`, serves it on http://127.0.0.1:18000 (a
secure context, so the page may use `ws://127.0.0.1`), then per direction
starts `tools/net_peer` as host (headless Godot, or headless Chrome on
`?tool=net_peer&role=host&signal=...`), reads its `NET_PEER CODE`, starts
the other runtime as guest with that code, and compares both peers'
`NET_PEER HASH <tick> <hash>` lines (every confirmed checkpoint). After
`NET_PEER DONE` the host sends its last checkpoint as a 120 KB SNAPSHOT
(BULK, 8 chunks; padded with random bytes) that the guest must receive
intact and equal to its own. PASS = both DONE OK (no resyncs), the same
checkpoints on both, all equal, bulk probe intact. Logs:
`builds/web-tools/e2e/`. `net_peer` alone: `godot --headless
res://tools/web_tools.tscn -- tool=net_peer role=host signal=ws://...`
or `tools/web_tools.sh tool=net_peer role=guest code=... signal=...`.

`net_peer` is Session + RollbackDriver as in `tests/net_webrtc_session_test`:
two human slots, one per peer, each fed by a `CpuInput` "pad", so real
inputs cross the wire, get predicted and rolled back; the config gets the
web caps (`apply_platform_caps`, `includes_platform(web)`) like a room.

**Verified (2026-10-30)**, Chrome 150 headless (WASM, `web_nothreads`)
↔ Linux editor binary + webrtc-native, same machine, input delay 0,
1800 ticks: versus and co-op (BRAWL, field cap 6), browser host and
browser guest: 60/60 checkpoint hashes equal in all four runs, 0
resyncs, ~15–30 ms RTT on loopback (frame-quantized; max 86), 0–188
rollbacks per peer (≤ 281 rolled-back ticks), bulk probe intact both
ways. Findings:

- **Browser receive buffer (fixed).** Godot's `WebRTCDataChannelJS`
  copies each incoming message into a 64 KiB ring per channel until the
  next `poll()`; past that it logs "Buffer full! Dropping data." and drops
  the message, on a *reliable* channel too. A 120 KB BULK message sent at
  once lost 4 of its 8 chunks in the browser (desktop's webrtc-native
  queue has no such limit). `WebRtcTransport` now paces RELIABLE/BULK
  chunks (`webrtc_send_budget_bytes`, one 16 KB chunk per frame per
  channel): the probe arrives intact. Residual risk: a receiving browser
  that stalls ≳ 3 frames in the middle of a large transfer still overflows
  (JS delivers the backlog in one go); only RESYNC / drop-in snapshots are
  that big.
- **put_packet / bufferedAmount on web.** The JS glue's `send()` returns
  OK whenever the channel exists (no try/catch; a send on a non-open
  channel would throw inside the call, which is why `send()` checks the
  ready state first), so `link.failed` never triggers in the browser.
  `get_buffered_amount()` is real there (121659 right after the 120 KB
  burst before pacing, 16000 with it); webrtc-native always reports 0.
- **Data channel options.** The web glue hands the Dictionary to
  `createDataChannel` as JSON, so the keys must be `RTCDataChannelInit`
  names: ours (`negotiated`, `id`, `ordered`, `maxRetransmits`) are, and
  the negotiated ids match across runtimes (`NET_PEER CHANNELS`). Reading
  back: a reliable channel's `get_max_retransmits()` is 0 on web (JS
  `null`) but -1 on desktop; don't use it to tell reliable from
  unreliable.
- **JSON numbers.** Both runtimes parse signaling JSON in GDScript
  (`WebSocketPeer` + `JSON`), so numbers are floats on both; `_int()`
  covers `peer`/`from`/`index`. Nothing browser-specific.
- **CONNECTED timing.** The guest reaches WELCOME 13–24 frames after
  starting (signaling connect, ICE, DTLS, SCTP, HELLO): browser and
  desktop alike.
- Chrome normally hides its host candidates behind mDNS (`*.local`,
  which libjuice may not resolve); on one machine the link forms either
  way round.
  Not yet checked: two machines on a LAN without STUN, and a real WAN.

## Performance in the browser

**Measured (2026-10-30, Ryzen 5 5500U, Chrome 150; table in SPEC_online.md
§12.1 "Browser").** `tools/web_tools.sh tool=bench mode=coop humans=2
enemies=4` runs `tools/net_bench` in the browser. The sim in WASM costs
~1.6× the native release template (~1.3× the editor binary): an 8-tick
rollback at 6 fighters is 4.25 ms mean in Chrome vs 2.63 ms native. 1v1 is
far inside the 8 ms budget (full rollback ≤ 4.2 ms). At the default online
field of 6 fighters, a typical frame is ~4.3 ms p95 but a full 8-tick
rollback frame is 9.0 ms p95, over budget; 8 fighters is 12+ ms.

So a session with a browser peer gets **caps, as match config**: the host
calls `MatchConfig.apply_platform_caps(session.includes_platform("web"))`
when it starts a match (`OnlineRoom._begin`, rematches too), which sets
`MatchConfig.online_field_cap = Tuning.coop.online_field_cap_web` (6, same
as today; `CoopRun.field_cap_for` reads it) and
`MatchConfig.max_rollback_frames = Tuning.net.max_rollback_frames_web` (6;
`RollbackDriver.max_rollback_frames` reads it, ~7 ms full rollback). Both
travel in MATCH_START, so every peer simulates the same field; 0 = the
normal Tuning values. Slower devices (phones) need their own measurement:
open the Web Tools export there with `?tool=bench&...`.

Other consequences:

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
  check. If hashes differ, rooms reject mixed platforms until fixed
  (`Tuning.net.cross_play` = false). Check passed 2026-10-30, so it is on.
- The web export presets exclude `addons/webrtc_native/*` (desktop-only
  GDExtension, ~16 MB of .so/.dll that `exclude_tags` alone would still
  pack). Debug web entry points: "Web Probe" (`tools/web_probe.sh`,
  presentation) and "Web Tools" (`tools/web_tools.sh`, replay hashes and
  net_bench; bundles `tools/replays/*.ghr`); the normal "Web" preset
  excludes `tools/`.
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
  under `max_packet_bytes`). Chunks are paced, at most
  `Tuning.net.webrtc_send_budget_bytes` (16 KB) per channel and link per
  frame: the browser's data channel keeps only 64 KiB of received messages
  between two polls and drops the rest (see "Cross-play end-to-end check").
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
  default: on web, a `?signal=` page query, else
  `Tuning.net.web_signaling_url`, else the page's own origin +
  `Tuning.net.signaling_path` (`/signal`; wss on an https page, so the
  certificate accepted for the page covers it: `tools/serve_web.py` forwards
  it on the LAN, a reverse proxy when deployed); on desktop
  `Tuning.net.signaling_url` (debug builds: `dev_signaling_url`). An
  unreachable server's error names the URL and the setting.
- Mobile browsers: the Web presets enable `html/experimental_virtual_keyboard`;
  without it an Android keyboard shows up but its text never reaches a
  LineEdit (IME input isn't plain key events).
- Web join links: `<page url>?room=CODE`; the page reads `room` at boot
  (`JavaScriptBridge`) and goes to the join flow.

## Open questions

- Where will the game and the servers be hosted? (Defaults above work
  anywhere; deploy steps in `server/README.md`.)
