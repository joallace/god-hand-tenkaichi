# Online play — spec

Status: agreed in interview, 2026-10-19. Not implemented. Builds on the
co-op/teams work (SPEC.md): teams of N, `EntityFactory`, director
`save_state`/`load_state`, deterministic `CpuBrain`. Numbers marked
*(tunable)* are starting picks that will live in `Tuning.net`, not decisions.

## 1. Goal

Play every mode over the internet: versus (1v1, 2v2, free-for-all) and co-op
(Brawl/Waves) with up to **4 humans** spread over up to 4 machines, any number
of them on the same machine (couch + online), plus host-configured CPU slots.
Linux ↔ Windows crossplay.

Non-goals for this project: spectators, a replay *viewer* (files are
recorded now, see §11), matchmaking/ranked, host migration, anti-cheat beyond
"peers only send inputs", mobile/ARM/console crossplay.

## 2. Decisions (interview summary)

| Topic | Decision |
|---|---|
| Netcode | **Rollback, P2P-style** (GGPO model): every peer runs the full sim, predicts missing remote input, re-simulates on correction. Small input delay on top. |
| Connectivity | **Direct IP:PORT now** (+ UPnP attempt), **rendezvous/relay server later** behind the same `Transport` interface. |
| Topology | **Host-relayed star**: only the host needs a reachable port; clients send to the host, the host forwards. Wire format is **mesh-ready** (§5.2) so a later hybrid (direct pairs where hole-punching works, host forwarding where not) is a transport-only change. |
| Determinism | **Floats + `DetMath` + checks**: our own `sin`/`cos`/`atan2` in sim code, a lint test banning libm-backed engine calls in sim code, per-tick state hashes, a cross-OS replay hash test, the Godot version pinned in the handshake. No fixed-point (§6 explains why). |
| Scope | N-peer design from the start; delivery staged 1v1 → co-op → n-vs-n / couch+online (§15). |
| Presentation under rollback | Cosmetic events are **muted during resim and deduplicated**; stats and match-ending transitions act on **confirmed** ticks only (§9). |
| Transport | **Raw `ENetConnection`** packets (no `MultiplayerAPI`/`@rpc`). |
| Menus | **One unified lobby** for local and online play; "Open online" turns a local lobby into a hosted room. |
| Rules | **Host edits shared rules**; any change un-readies everyone. |
| Pause | **Never stops the sim online**; pause opens an overlay and the local fighter gets neutral input. |
| Input delay | **Auto from ping**, user override in settings. |
| Disconnect | Versus: **forfeit**. Co-op: **CPU takes over** the slot. Host leaving ends the session. |
| Drop-in | Co-op **Waves only, at breathers**; a reconnecting player **reclaims** their own slot. Brawl: lobby joins only. |
| Desync | **Resync from the host's snapshot** and dump logs; repeated desyncs end the match. |
| Replays | **Auto-keep last N + "Save replay"** on results; no viewer yet. |
| Join entry | **Text field** (keyboard/paste) the first time, **recent hosts list** after. |
| Teams | Players pick their team (or FFA); the host can move/lock. |
| After match | **Back to lobby, room kept**; "Rematch" needs every human to confirm. |
| Views | Each machine split-screens **its own** local players (current `ViewLayout` rule). |
| Co-op perf | **Online field cap** (`coop.online_field_cap`, start 6) + a resim benchmark. |
| CPUs online | Allowed; the host adds them and sets level/character. |
| Names | Editable **profile name** in `user://online.cfg`. |
| Stats overlay | Debug toggle only (not a player-facing feature). |

## 3. Why rollback + direct IP (and what comes later)

- The sim was built for this: fixed 60 Hz `sim_tick`, `InputFrame` is the only
  input, everything round-trips `save_state`/`load_state`, `EntityFactory`
  rebuilds spawned/freed entities. Delay-based lockstep would add ping to
  every dodge/parry; server-authoritative would discard the determinism work.
- Measured on the dev machine (2026-10-19, `tools/coop_sim`, 2 CPU humans):
  ~0.5 ms per tick with 8 enemies on the field, not counting `save_state`.
  An 8-frame rollback is then ~4 ms + snapshot cost: affordable, but co-op is
  the case to watch (§12).
- Direct IP fails behind CGNAT and strict NATs. The later fix is a small
  self-hosted **rendezvous + relay** (noray-style: UDP hole punching, relayed
  fallback, short room codes). Alternatives considered for that milestone:
  WebRTC (`webrtc-native` GDExtension + signaling + STUN/TURN — same idea,
  heavier), Steam Datagram Relay (GodotSteam; free relays and friend invites,
  but needs a Steam app and ties online to Steam). Nothing in this spec
  depends on which one is chosen.

## 4. Architecture

New folder `core/net/` (mode-agnostic, no presentation):

```
Net (autoload, core/net/net.gd)      session lifetime across scenes
 ├─ Transport (interface)            send(peer, channel, bytes) / poll() -> events
 │   ├─ EnetTransport                raw ENetConnection, host or client
 │   └─ LoopbackTransport            in-process, simulated latency/jitter/loss (tests, --net-sim)
 ├─ Session                          peers, handshake, lobby state (host-authoritative), routing
 ├─ RollbackDriver                   drives MatchDirector.step() online (§7)
 ├─ InputHistory                     per-slot confirmed/predicted frames by tick
 ├─ TimeSync                         frame-advantage tracking, stall/slowdown
 ├─ StateHash                        hash of save_state(); checksum exchange
 ├─ ReplayRecorder / ReplayReader    §11
 └─ Upnp helper                      threaded port mapping (§10.4)
```

- `Net` survives scene changes (`Game.goto`), so the lobby → match → results →
  lobby cycle keeps connections. Offline play never touches it (`Net.session
  == null`).
- `MatchDirector` stays mode-agnostic. Online, `auto_step = false` and the
  `RollbackDriver` calls `step()`, `save_state()`, `load_state()`. New on the
  director: `var resimulating := false` (read by presentation) and the
  sim-command hook (§7.4).
- `MatchConfig` gains `to_dict()`/`from_dict()` (Resources never go over the
  wire). `PlayerSlotConfig` gains `owner_peer: int` (0 = local/offline) and
  `display_name: String`. All peers share one config; each peer derives
  `input_kind` per slot: CPU stays CPU, `owner_peer == me` → LOCAL (its
  `device_kind`/`device_id` only mean anything on the owner), otherwise →
  NETWORK. `local_view_slots()` and `layout()` therefore already give each
  machine its own split screen.

## 5. Protocol

### 5.1 Channels

| ENet channel | Mode | Carries |
|---|---|---|
| 0 | unreliable | `INPUT`, `INPUT_ACK`, `PING`/`PONG`, `HASH` |
| 1 | reliable, ordered | handshake, lobby state, match start, sim commands, drop/rejoin control |
| 2 | reliable, ordered | bulk: snapshots (resync, drop-in), compressed |

Messages are `PackedByteArray`s with a 1-byte type and a fixed little-endian
layout (no `var_to_bytes` for hot messages). Bulk payloads use
`var_to_bytes(dict)` + zstd, decoded with `bytes_to_var` (**never**
`bytes_to_var_with_objects`). Every message has a size cap; malformed or
oversize packets are dropped, and only the host may send lobby/snapshot/command messages.

### 5.2 Mesh-ready input messages

```
INPUT  { origin_peer:u8, ack_tick_from_dest:u32,
         slots: [ { slot:u8, first_tick:u32, count:u8, frames: count × 6 bytes } ] }
frame = move_x:i8, move_y:i8, held:u16 (PAUSE bit stripped), dodge:u8, target_request:i8
```

- Each frame is tagged with origin peer, slot and tick, never with "who
  forwarded it". The host forwards `INPUT` unchanged (it rewrites only the ack
  field per destination). Acks are tracked **per (origin, destination)**, so
  mesh/hybrid routing later only changes which link a message travels on.
- Redundancy: each packet repeats every frame since the destination's last
  ack (capped at `max_rollback_frames + input_delay_max`), so loss costs
  nothing until it is sustained. Edge bits (`pressed`/`released`) are not sent:
  `InputSource.poll` derives them, deterministically, from `held`.
- `PING`/`PONG` every `ping_interval_frames` *(tunable, 30)* per link; RTT
  feeds TimeSync, auto input delay and the lobby ping badge.

### 5.3 Handshake

`HELLO { protocol_version, engine_version (Engine.get_version_info hex),
game_build (version string stamped at export, "dev" in editor), content_hash,
name, reconnect_token? }` → `WELCOME { peer_id, lobby_state }` or
`REJECT { reason }`. Reasons: version mismatch (show both versions), content
mismatch, room full, match in progress (not joinable), banned name chars, host
closing.

`content_hash` = hash over `var_to_bytes` of every loaded tuning Resource,
MoveData and CharacterDef, in sorted path order. Hand-tuned `.tres` files that
differ between machines would desync, so this catches them up front.

## 6. Determinism (Linux ↔ Windows)

Why not fixed-point: any desync source (a sim var missing from
`save_state`, a dictionary iterated in a different order, state set in
`_ready` instead of `spawn_init`) needs the same checksum harness anyway. On
x86-64, IEEE `+ − × ÷ sqrt` are bit-identical between the official Linux and
Windows builds (SSE2, no FMA contraction without `-mfma`). What differs is
the **transcendental functions** in the platform's libm (`sin`, `cos`, `atan2`,
`pow`, `exp`) and engine helpers built on them. Fixed-point in GDScript would
also be slower (extra shifts/multiplies per operation, GDScript trig and sqrt)
and would touch Fighter, CombatSystem, projectiles, CpuBrain, MoveData and every
`.tres`. Revisit only for ARM crossplay.

Rules:

1. **`DetMath`** (`core/sim/det_math.gd`, static): `sin`, `cos`, `atan2`,
   `angle_to(a, b)`, `rotate_y(v, angle)`, `yaw_basis(yaw)`, `deg/rad`
   conversions, built from basic ops only (range reduction + minimax
   polynomials). Every call site in sim code switches to it. Current
   sites (2026-10-19): `Fighter` (yaw, `_fwd`/`_right`, `rotated` in vanish
   placement, guard cone `angle_to`, `Basis(UP, yaw)`), `Targeting`
   (`angle_to`, `atan2`), `EncounterDirector` cone, `CoopRun` spawn ring and
   regroup, `MatchDirector.spawn_transform`.
2. **Lint test** (`tests/determinism_lint_test`): scans sim scripts
   (`core/match`, `core/sim`, `gameplay/` minus `fighter_visual.gd` and other
   view-only files) and fails on `sin(`, `cos(`, `tan(`, `atan`, `asin`, `acos`,
   `pow(`, `exp(`, `log(`, `.angle()`, `angle_to`, `rotated(`, `slerp`,
   `look_at`, `from_euler`, `Basis(`, `Quaternion`, `lerp_angle`, `randf`/`randi`
   (global RNG), `Time.`, `OS.get_ticks`, and iteration over Dictionaries whose
   insertion order isn't fixed. An allowlist comment marks proven-safe lines.
3. Positions stay on `Node3D` (`real_t` = float32 in official builds, the same
   on both OSes). Setting `global_basis` from `DetMath.yaw_basis` is fine:
   visuals may use any math.
4. **State hash** (`StateHash.of(director)`): a hash of
   `var_to_bytes(director.save_state())`. Floats are compared bitwise.
5. **Cross-OS check**: `tools/replay_hash.tscn -- replay=<file>` prints the
   per-tick hash stream. CI-able on Linux; run the same replays on a real
   Windows machine (Wine's CRT is not the Windows CRT, so Wine is only a smoke
   test). `export_presets.cfg` has Linux + Windows presets.
   Wine smoke test (2026-10-19, official 4.7.2 win64 console binary run on
   the project folder): a CPU-only versus replay (3600 ticks) and a co-op
   Waves replay (2078 ticks) recorded on Linux match all checkpoints. It first
   caught a real drift: inside `DetMath`, bare `sin(`/`cos(`/`atan(` calls
   resolve to the *global* built-ins, so `yaw_basis`, `atan2` & co. were
   libm-backed (glibc rounds correctly, so Linux-only tests couldn't see it);
   the lint test now requires DetMath to call itself qualified. Diff two
   states with `replay_hash -- replay=<f> dump=<tick> out=<file>`.
   Still to do: the same check on a real Windows machine.
6. All peers must run the **same Godot version** (handshake).

## 7. Rollback driver

### 7.1 Per frame (in `_physics_process`, 60 Hz)

1. Pump the transport. Store arriving remote frames in `InputHistory`
   (confirmed). If a confirmed frame differs from what was predicted for a
   tick ≤ current, mark `rollback_to = min(rollback_to, tick)`.
2. If `rollback_to` is set: `hub.rollback_to(rollback_to)` (drops unconfirmed
   presentation events, ignores the signals the load fires),
   `load_state(snapshot[rollback_to - 1])`, set
   `director.resimulating = true`, step up to the current tick, then clear the flag.
3. Sample local devices once per local slot; write the frame for tick
   `current + input_delay`; send `INPUT`. The local `PAUSE` edge is consumed
   here (§10.3) and stripped from the frame.
4. **Advance or stall**: advance one tick unless `current + 1 −
   min_confirmed_tick(all remote slots) > max_rollback_frames` *(tunable, 8)*
   or TimeSync asks to wait this frame. While stalled for more than
   `stall_warning_frames` *(tunable, 30)*, show "Waiting for <name>…".
5. `save_state()` into a ring buffer of `max_rollback_frames + 2` entries
   (only unconfirmed ticks need one).
6. Advance `confirmed_tick` (all slots confirmed); emit confirmed events
   (§9, `hub.confirm_through(confirmed_tick)`); every `checksum_interval` *(tunable, 30)* confirmed ticks send `HASH`.

Catch-up: when a frame hitch leaves the peer behind (e.g. a window drag on
Windows), run up to `max_catchup_ticks` *(tunable, 4)* steps in one frame.

### 7.2 Input sources online

All slots read from `InputHistory` through the existing `NetworkInput`
(renamed role: "history-backed source"). That includes local slots, because
during resim a local slot must replay what was recorded for that tick, not
poll the pad again. Prediction = repeat the last confirmed frame with `dodge`
cleared (a flick is an edge; repeating it would predict a second dodge).
`InputHistory` is *not* part of `save_state` (it is the network log); the
sources' edge state (`_previous`) is, as today. CPU slots keep `CpuInput`
and are re-simulated like everything else.

### 7.3 Input delay and TimeSync

- `input_delay` auto = clamp(ceil(RTT_max/2 / 16.67 ms) − rollback_comfort,
  input_delay_min, input_delay_max), with `rollback_comfort` *(tunable, 3)*,
  `input_delay_min` 1 and `input_delay_max` 6 *(tunable)*.
  RTT_max = worst link to any peer the local inputs must reach (through the
  host in the star). Settings override: "Auto" or a fixed 0–6. Each peer's
  delay is its own; it only changes at match start (changing it mid-match
  would drop or duplicate frames).
- TimeSync (GGPO-style frame advantage): every peer estimates
  `local_tick − (remote_tick + RTT/2·60)` per remote peer, averaged over
  `timesync_window` *(tunable, 60)*. If it is ahead by more than
  `timesync_threshold` *(tunable, 1.5)* frames, it waits one frame every
  `timesync_interval` *(tunable, 20)*. The slowest peer sets the pace, so a
  peer that can't keep 60 Hz slows the session instead of desyncing.

### 7.4 Sim commands

Changes that aren't player input but must happen at the same tick everywhere go
through a **host command stream**: `CMD { tick, kind, args }` on channel 1,
issued for tick ≥ host's current + input delay + 1, and applied by the
director at the start of that tick's `step()`. Peers that already passed
that tick roll back to it, the same as a late input.

| kind | args | effect |
|---|---|---|
| `CPU_TAKEOVER` | slot, cpu_level | slot's source becomes `CpuInput` (co-op disconnect) |
| `RECLAIM` | slot, peer | slot returns to that peer's input (reconnect) |
| `JOIN` | slot, peer, character, name | `spawn_fighter` on team 0 with ENTERING (drop-in) |
| `FORFEIT` | team | versus: ends the match, that team loses (`&"forfeit"` reason) |

Which source each slot uses (`slot_controller`: PLAYER / CPU) becomes director
state and goes in `save_state`, so rollback across a takeover is correct.

## 8. Desync handling

1. Each peer sends `HASH { tick, hash }` for confirmed ticks; the host compares.
2. On mismatch the host sends `RESYNC { tick, snapshot }` (channel 2) from
   its saved confirmed state. Clients `load_state` it, drop their ring
   buffer, and re-simulate to the present with their `InputHistory`.
3. Each side writes `user://desync/<date>_<tick>_<peer>.txt`: both
   `var_to_str(save_state)` at the mismatched tick, the last 600 ticks of inputs,
   versions and content hash. A diff of two dumps points at the drifting variable.
4. After `max_resyncs_per_match` *(tunable, 3)* the match ends with
   "Connection error (desync)" and both sides save the replay.

## 9. Presentation under rollback

Presentation stays observe-only. Two event streams:

- **Immediate (cosmetic)**: `MatchEventHub` already dedupes per frame. It
  extends that to key = (tick, sim_id, kind). While
  `director.resimulating`, events are recorded but not emitted, except a key
  never seen before whose tick is within `late_fx_window` *(tunable, 6)*
  frames of now: it plays late (a hit that the correction revealed). Events
  that the rollback erased stay played (an accepted "ghost" spark/sound).
  VFX, SFX (`MatchSfx`), camera shakes and HUD flashes use this stream.
- **Confirmed**: the hub buffers events per tick; a rollback to `t` drops
  buffered events ≥ `t`; when `confirmed_tick` passes a tick its events are
  emitted on `confirmed_event`. `RunStats`, the replay's event marks and
  **match flow** use this stream. `match_ended` / `run_ended` / `round_ended`
  only move scenes or show banners once confirmed. Otherwise a mispredicted
  KO could end the match.

State-shaped visuals (fighter poses, health bars, timer, keyed SFX loops like
charging) read current sim state every frame, so they are correct after any
resim automatically. A loop that only starts on an event must instead be
driven from state.

Offline: the hub treats every tick as confirmed immediately, so offline
behaviour doesn't change.

## 10. UI / UX

### 10.1 Main menu

`Play` · `Join online` · `Controls` · `How to play` · `Settings` · `Quit`.
"Online — Coming soon" and the separate Local versus / Versus CPU / Co-op
entries go away. `Settings` holds the profile name, input delay (Auto /
0–6), default host port and the debug net-stats toggle (plus any existing
options moved here).

### 10.2 Unified lobby (replaces `join_screen`)

One screen for local and online. It generalizes the current join screen:
pads/keyboard join into free slots, and the shared rows below the slots.

- **Top bar**: room status.
  - Local: `Local · [Open online]`.
  - Hosting: `Hosting · 192.168.0.12:7777 · Public 203.0.113.5:7777 (UPnP) · [Copy] · [Close room]`,
    or `UPnP failed — forward UDP 7777 or use LAN/VPN`.
  - Guest: `Connected to <host name> · 38 ms · [Leave]`.
- **Slots**: up to `max_fighters` *(tunable, 4)* fighters, of which at most
  4 humans. Each slot shows name, source (pad/keyboard icon, "Online · 38 ms",
  or "CPU Lv n"), character, team, ready. Remote slots are display-only.
  On each machine, local devices join only free slots.
- **Mode row** (host only): Versus / Co-op. Then the mode's rows, as in the
  join screen today (Versus: rounds, timer, friendly fire; Co-op: SPEC.md §9
  rows, with `online_field_cap` limiting Enemies-on-field when online).
- **Teams** (Versus): each slot has a Team row (A / B / FFA = own team). Players
  change their own; the host can change anyone's and toggle "Lock teams".
  Start requires ≥ 2 non-empty teams. Co-op: all humans + ally on team 0.
- **CPU slots** (host only): `Add CPU` / remove, level, character.
- **Ready / start**: any rule change by the host un-readies everyone.
  Countdown (`lobby_countdown_frames` *(tunable, 180)*) when every human is
  ready, so it can be cancelled; it then starts for all.
- Guests can open the lobby while the host is still picking; they can pick
  character/team and ready up.

### 10.3 Pause overlay (online)

Pause opens the overlay without stopping the sim. The local slot(s) on that
machine send neutral frames while it is open. Items: Resume, Controls (view
only), Net stats (debug toggle), `Forfeit` (versus) / `Leave run` (co-op;
your slot becomes CPU, like a disconnect), `Quit to menu`. Other players see
a small "⏸ <name>" tag on that player's HUD.

### 10.4 Join online screen

Address field (`IP:PORT`, hostname or `[IPv6]:PORT`; default port if
omitted; keyboard + clipboard paste), `Connect`, then a **recent hosts** list
(last `recent_hosts_max` *(tunable, 8)* successful joins with host name and
date, pad-navigable, delete entry). Status line: connecting… / timed out /
the REJECT reason. Then it goes to the lobby as a guest. Stored in
`user://online.cfg`.

### 10.5 Hosting

`Open online` binds UDP `default_port` *(tunable, 7777, settings override)*
and starts a UPnP mapping in a thread (discovery takes seconds and must not
block the UI). The mapping is removed when the room closes. If the bind fails
the error says the port is in use. Windows will show its firewall prompt the
first time; the How-to-play page mentions it.

### 10.6 HUD and results

`MatchConfig.player_tag` returns the slot's `display_name` for humans when
online (still `P1`… offline, `CPU` for CPUs). The debug net overlay shows ping
per peer, input delay, rollbacks/s and their average depth, stalls, packet loss and last hash tick.
Results: `Rematch` (needs every human to confirm; new seed, same config),
`Lobby` (host takes the room back to the lobby, everyone keeps their
connection), `Save replay`, `Leave`.

## 11. Replays

`user://replays/last_<n>.ghr`, rolling `replay_keep_count` *(tunable, 10)*,
written for **every** match (offline too); "Save replay" copies it to
`user://replays/saved/<date>_<mode>.ghr`. Format (var_to_bytes + zstd):
`{format_version, engine_version, game_build, content_hash,
config: MatchConfig.to_dict(), inputs: {slot: PackedByteArray of 6-byte
frames}, commands: [CMD...], end_tick, hashes: every Nth tick}`. Replays from a
different build/content hash show "made with another version".
Uses now: desync debugging, `tools/replay_hash`, determinism tests. Viewer: later.

## 12. Performance

- Budget per frame on the slowest peer: `max_rollback_frames × step +
  save_state + load_state` must stay ≤ ~8 ms (half a 60 Hz frame).
- `tools/net_bench.tscn -- enemies=N humans=M` measures step,
  `save_state`, `load_state` and an 8-tick resim. Run it per milestone and
  record results in this spec.
- `coop.online_field_cap` *(tunable, 6)* clamps `field_cap` online; raise it
  if the bench allows.
- Snapshot cost: the ring buffer holds Dictionaries. If save_state dominates,
  snapshot only ticks that can still be rolled back (unconfirmed), and
  consider PackedArray-based per-entity state later.
- During resim, visuals do nothing (they read state on `_process`), so resim
  is sim-only cost.

### 12.1 Bench results

2026-10-19, dev box (AMD Ryzen 5 5500U, headless, editor open in the
background), `tools/net_bench.tscn` defaults: 600-tick warmup, 1800 measured
ticks, rollback 8, CPU humans at level 7, enemies at level 3, seed 7. Times in
ms (mean / p95). "Est." is the §12 formula `8×step + save + load` (p95s);
"Full" adds the snapshot a real driver takes on every re-simulated tick,
`8×(step + save) + load` (p95s). Every run: determinism OK (~223 rollbacks
each re-simulated byte-identically).

| Run | Fighters | step | save_state | load_state | var_to_bytes+hash | snapshot | 8-tick rollback | Est. | Full |
|---|---|---|---|---|---|---|---|---|---|
| versus 1v1 | 2 | 0.09 / 0.15 | 0.08 / 0.11 | 0.10 / 0.15 | 0.07 | 8 KB | 0.77 / 1.03 | 1.4 | 2.2 |
| co-op 2 humans + 4 | 6 | 0.36 / 0.45 | 0.23 / 0.25 | 0.25 / 0.37 | 0.18 | 23 KB | 2.97 / 3.42 | 4.2 | 5.9 |
| co-op 2 + 6 | 8 | 0.52 / 0.68 | 0.31 / 0.35 | 0.33 / 0.58 | 0.24 | 31 KB | 4.14 / 4.72 | 6.4 | 8.8 |
| co-op 2 + 8 (`coop.field_cap=10`) | 10 | 0.72 / 0.92 | 0.40 / 0.50 | 0.43 / 0.68 | 0.31 | 38 KB | 5.65 / 6.51 | 8.6 | 12.1 |
| co-op 4 + 6 (`coop.field_cap=10`) | 10 | 0.73 / 0.94 | 0.39 / 0.45 | 0.41 / 0.65 | 0.31 | 38 KB | 5.76 / 6.62 | 8.6 | 11.8 |

What it implies:

- Cost is linear in fighters on the field and independent of how many are
  human: ~0.07 ms step, ~0.04 ms save, ~0.04 ms load and ~4 KB snapshot per
  fighter. Projectiles are noise next to fighters.
- 1v1 is far inside budget (≤ 2.2 ms even with per-tick resim snapshots).
- `save_state` is ~60% of `step`, so snapshotting every resimulated tick
  costs almost as much as the resim itself; "Full" is the honest worst case.
- **`coop.online_field_cap` = 6 stays.** At 6 fighters the full worst case
  is 5.9 ms p95 on this mid-range laptop CPU, ~25% headroom for slower peers.
  8 fighters is 6.4 ms by the §12 formula but 8.8 ms with resim snapshots,
  over budget; 10 is over either way. Raising the cap to 8 needs one of:
  cheaper snapshots (§12 bullet above: skip snapshots that can't be rolled
  back to, or PackedArray state), `max_rollback_frames` ≤ 6 for big fields,
  or a faster minimum spec. Rerun the bench after any of those.
- `var_to_bytes` + hash of a full snapshot is ~0.2–0.3 ms; at
  `net.checksum_interval` = 30 that is negligible.

## 13. Disconnects, drop-in, reconnect

- **Detection**: no packets from a peer for `disconnect_timeout_frames`
  *(tunable, 180)*, or an ENet disconnect. Before that the session just
  stalls with "Waiting for <name>…".
- **Cut point**: the host decides `last_tick` = the last tick it confirmed for
  that peer. It forwarded everything it had, so all peers agree. It then
  issues the command at `last_tick + 1`.
- **Versus**: `FORFEIT { team }` for the dropped player's team (a 2v2
  partner on that team loses too; see §16). The others see results with
  "<name> disconnected".
- **Co-op**: `CPU_TAKEOVER { slot, cpu_level = coop ally level }`. The slot
  keeps its health/meter and shows "CPU (<name>)". If every human peer but
  the host leaves, the run goes on with CPUs.
- **Host leaves / host connection lost**: everyone gets "Host left the
  session" and returns to the main menu. The replay is saved. No migration.
- **Reconnect (co-op Waves)**: on WELCOME the host gives each guest a random
  `reconnect_token` (memory only). A guest that comes back with it during the
  same run is flagged as reconnecting. **Drop-in**: a new peer may join a
  running Waves run while free human slots remain.
  Both follow the same path:
  1. The host sends config + a snapshot of its latest confirmed tick +
     inputs/commands since then (channel 2).
  2. The joiner loads it, fast-forwards, and runs in sync showing a spectator
     view ("Joining at the next wave…").
  3. At the next breather the host issues `RECLAIM` (reconnect) or `JOIN`
     (new slot, character picked from a small overlay while waiting; enters
     with the ENTERING state).
  Brawl and Versus reject mid-match joins ("match in progress").

## 14. Tuning

New category `net` (`core/tuning/net_tuning.gd`, `data/tuning/net.tres`,
registered in `tuning_db.gd`): `default_port`, `max_rollback_frames`,
`input_delay_min`, `input_delay_max`, `rollback_comfort`,
`timesync_window`, `timesync_threshold`, `timesync_interval`,
`max_catchup_ticks`, `stall_warning_frames`, `disconnect_timeout_frames`,
`ping_interval_frames`, `checksum_interval`, `max_resyncs_per_match`,
`late_fx_window`, `lobby_countdown_frames`, `replay_keep_count`,
`recent_hosts_max`, `max_humans` (4), `max_fighters` (4), `max_packet_bytes`,
`name_max_len` (16). In `coop`: `online_field_cap`.

Per-user settings (not tuning) go in `user://online.cfg`: name, input delay
mode, port override, recent hosts, debug overlay.

## 15. Milestones

0. **Offline groundwork** (no networking, all testable headless):
   `DetMath` + call-site migration + lint test; `StateHash`; replay
   recorder/reader + `tools/replay_hash`; `MatchConfig.to_dict/from_dict`,
   `owner_peer`, `display_name`; director `resimulating` flag, sim-command
   hook, `slot_controller` in save_state; `MatchEventHub` confirmed stream
   (offline = immediate); `tools/net_bench`; `export_presets.cfg` for Linux
   + Windows; **cross-OS hash check on a real Windows machine**.
1. **Rollback core over loopback**: `Transport`, `LoopbackTransport`,
   `Session` (minimal), `InputHistory`, `RollbackDriver`, `TimeSync`, desync
   resync. 1v1 in a headless test with simulated latency/jitter/loss.
2. **Online 1v1, playable**: `EnetTransport`, handshake/version checks,
   `Net` autoload, unified lobby (replaces join screen, keeps local modes
   working), join screen + recent hosts, UPnP, profile names, settings screen,
   pause overlay, forfeit on disconnect, results rematch/lobby, debug net
   overlay. Play-test Linux↔Windows over a real WAN.
3. **Online co-op**: Brawl/Waves for 2, then up to 4 humans; CPU ally
   online; `CPU_TAKEOVER`; online field cap tuned with `net_bench`.
4. **Drop-in / reconnect** at Waves breathers.
5. **n-vs-n and couch + online**: teams/FFA rows, lock, several local
   players per peer, per-machine split screen.
6. **Later**: rendezvous/relay server + room codes + hybrid mesh; replay
   viewer; spectators.

## 16. Tests to add

- `determinism_lint_test`: §6 rule 2.
- `det_math_test`: DetMath vs built-ins within tolerance, and exact
  reproducibility (fixed vectors with known bit patterns).
- `replay_test`: record a CPU-vs-CPU match and a co-op Waves run, replay
  them, and match the hash every N ticks and at the end. Also the format
  round-trip and the version-mismatch warning.
- `net_loopback_test`: 2 and 4 directors in one process over
  `LoopbackTransport` with latency 0–150 ms, jitter and 0–10 % loss; random
  and CPU inputs; all peers' hashes equal at every confirmed checkpoint, no
  stall when within budget, stall when a peer goes silent.
- `net_resim_fx_test`: forced mispredictions. Each event is emitted at most
  once, late events land within the window, `RunStats` counts only
  confirmed events, and a rolled-back KO never ends the match.
- `net_commands_test`: CPU takeover, reclaim, join and forfeit at a tick
  survive rollbacks across that tick; `slot_controller` round-trips.
- `net_desync_test`: corrupt one peer's state → resync restores equal
  hashes; dumps written; the limit ends the match.
- `net_protocol_test`: encode/decode of every message; oversize/malformed
  packets rejected; non-host lobby/snapshot messages ignored.
- `lobby_test` (replaces/extends `menus_test`): local flow unchanged;
  host-only rules; un-ready on change; teams/FFA start conditions; CPU slots;
  guest view built from host state. `ui_layout_test`: lobby with 4 slots
  (local + remote + CPU) fits.
- `net_dropin_test`: snapshot transfer + fast-forward + JOIN at breather
  matches the host's hash.

## 17. Risks and open questions

- **2v2 forfeit is harsh**: one drop loses the match for the partner.
  Alternative: CPU takeover in team versus, forfeit only when a team has no
  human left. Decide when milestone 5 lands.
- **Windows CRT vs DetMath coverage**: engine internals (`Vector3.normalized`
  is sqrt-only, fine; anything else hidden?) only show up in the cross-OS
  hash test, so run it early (milestone 0).
- **save_state cost in GDScript** with 8+ CPU brains may break the budget;
  `net_bench` decides `online_field_cap`.
- **Big host commands** (JOIN with an ENTERING fighter) cause long resims on
  peers that are far ahead; issuing them a few frames later than the minimum
  is a cheap fix.
- **No NAT traversal** until milestone 6: many friends will need port
  forwarding, LAN, or a VPN (Tailscale/ZeroTier). The UPnP message and How to
  play must say so.
- **IPv6 / dual-stack** binding with ENet on Windows: verify in milestone 2.
- **Event dedupe keys** need stable `sim_id`s across rollback. `next_sim_id`
  is already in save_state, so re-spawned entities get the same ids.
- **Unified lobby rewrite** touches the most-tested menu; keep the join
  screen's behaviour (memory of last setup, co-op rows) and its tests green.
