# God Hand Tenkaichi

3D Godot 4.7 fighting game: God Hand (right-stick dodges) x Budokai Tenkaichi
(ki charging, specials, teleport/vanish), ground-only — fighters never fly.
Typed GDScript. Godot binary: `/home/joallace/opt/Godot_v4.7.2-stable_linux.x86_64`.

## Testing

```sh
tests/run_all.sh            # all headless test scenes; non-zero exit on failure
tests/run_all.sh combat     # name filter
```

Tests are scenes (`tests/*.tscn`), not `godot --script`: bare scripts run
before autoloads exist. See `tests/README.md`. Always wrap Godot calls in
`timeout`. Run the suite before committing.

## Architecture

- `core/` — mode-agnostic foundation.
  - `input/`: `InputFrame` (the only thing gameplay reads; fighter-space move,
    `Btn` bitmask, dodge flick), `InputSource` subclasses (`LocalDeviceInput`
    per device id, `CpuInput` wrapping a `CpuBrain`, `NetworkInput` reading
    an `InputHistory`),
    `Bindings` autoload (rebindable controls, `user://controls.cfg`). Sources
    round-trip through `save_state`/`load_state` with the director.
  - `match/`: `MatchConfig` + `PlayerSlotConfig` (built by menus;
    `to_dict`/`from_dict` plain data for wire/replays, `from_dict` validates;
    `owner_peer`/`display_name`, `localize_for_peer`),
    `MatchDirector` (fixed 60 Hz tick loop, rounds, timer incl. infinite,
    world freeze, save/load state). Sim commands (`add_command`: CPU_TAKEOVER,
    RECLAIM, FORFEIT, JOIN stub, RESYNC_INPUTS on unpause) live in a log
    outside save_state and apply at the start of their tick's `step()`, so a
    rollback re-applies them; `slot_controller` (PLAYER/CPU per config slot)
    is state. `source_factory` overrides player sources; `inputs_polled` /
    `tick_completed` feed the replay recorder.
  - `sim/StateHash`: hash of `var_to_bytes(save_state())` (bitwise floats;
    save_state must build Dictionaries in a fixed order).
  - `net/`: `ContentHash` (tuning + moves + characters), `Replay` (.ghr file:
    config, human frames, commands, hashes; `save_auto` keeps
    `user://replays/last_<n>.ghr`, `save_copy`), `ReplayRecorder` (added by
    the match scene; no auto-keep headless), `ReplayPlayer` (playback with
    `ReplayInput`, verifies hashes). Online plan: SPEC_ONLINE.md.
  - `sim/SimEntity`: base for everything ticked by the director (stable
    `sim_id`, `spawn_desc()`). `sim/EntityFactory` rebuilds entities from
    those descriptors: `MatchDirector.load_state` frees/recreates projectiles
    and fighters (`spawn_fighter`/`remove_fighter`) to match the snapshot.
    A new spawnable type needs a factory case, `spawn_type()`, `spawn_init`
    and, if it links to other entities, `resolve_links()`.
  - Teams: every fighter has a `team` (default = slot, so 1v1 is two teams of
    one) and a `target` (there is no `opponent`); `wins` is indexed by team.
    Hitstop is per entity (`request_hitstop(participants, frames)`); only
    ultimate / counter guard / push-stop use `request_world_freeze`.
    Co-op (Mode.COOP, `MatchConfig.coop`): `CoopRun` (enemy queue, field
    cap, clear/wipe, waves + breather + endless curve; director signals
    `wave_started`/`wave_cleared`) inside the director, `EncounterDirector`
    attack tokens + grab lock (CpuBrain asks before attacking; the CPU ally
    revives downed teammates), DOWNED/OUT/REVIVE and ENTERING fighter
    states. Plan and milestones: SPEC.md.
  - `net/` (SPEC_ONLINE.md): `Transport` (packets on 3 channels: unreliable,
    reliable, bulk; host = peer 1) with `EnetTransport` (raw ENetConnection,
    `parse_address`) and `LoopbackTransport` on a `LoopbackNetwork`
    (deterministic in-process latency/jitter/loss, silence, link drops; tests).
    `Protocol`: static encode/decode, fixed layouts for hot messages,
    var_to_bytes (+zstd for bulk) for the rest, every decode validated.
    `Session`: handshake/rejects, peer table, host-relayed input routing with
    per-(origin, dest) acks and redundancy, PING/RTT, timeouts, host-only
    enforcement; it feeds the `InputHistory` (confirmed + used frames,
    prediction, misprediction ticks) that `NetworkInput` reads. `TimeSync`:
    frame advantage, wait frames, auto input delay. `RollbackDriver` (Node)
    joins them to a director: history-backed sources for every human slot,
    snapshot ring, rollback + resim (`director.resimulating`, hub
    `rollback_to`/`confirm_through`), stall/TimeSync, confirmed checkpoint
    hashes, host RESYNC + desync dumps, `issue_command`, disconnect ->
    FORFEIT / CPU_TAKEOVER. Tested end to end in `tests/net_loopback_test`
    (online co-op through rooms: `tests/net_coop_test`).
    `Net` autoload (`core/net/net.gd`): `host()`/`join()`/`leave()`, pumps
    the session outside matches (the match scene's driver pumps it during
    one), `OnlineSettings` (`user://online.cfg`: name, delay, port, recent
    hosts, overlay), `UpnpHelper` (threaded mapping), `pending_message` for
    the main menu. `OnlineRoom`: host-authoritative lobby (`LobbyModel`),
    phases lobby/match/results, `request()` ops (LOBBY_REQ from guests),
    countdown -> MATCH_START -> `Game.start_match` on every peer.
    Team versus (`LobbyModel.team_mode`): TEAM / Seat (CPU seats) / Lock
    teams rows; several local players per machine online (couch + online,
    `Bindings.profile_for` / `MatchConfig.binding_profile`); a peer's
    drop-out = CPU takeover, forfeit only when the humans left share one team
    (`RollbackDriver.drop_out_commands`).
  - `tuning/`: one Resource class per category, loaded by the `Tuning` autoload
    from `data/tuning/<key>.tres`.
  - `game.gd`: `Game` autoload, scene flow.
  - `settings/`: `Settings` autoload (presentation only, never read by the
    sim): `VideoSettings` (`user://video.cfg`: window mode/size, render
    scale + upscaler, vsync, FPS cap, motion smoothing, shadows, UI scale;
    defaults/options in `data/tuning/video.tres`) and `AudioSettings`
    (`user://audio.cfg`: volume per bus; buses in `default_bus_layout.tres`).
    `apply_video()` -> window/renderer + `video_applied`; `ViewLayout` pulls
    `configure_viewport()`. Window bits are skipped headless (`apply_display`).
  - `platform/PlatformCaps`: what the platform can do (window control, quit,
    UPnP, FSR, `net_backend()`); web = browser owns the window, no online
    yet (`Net.online_available()` gates every online menu entry). Read by
    Settings, menus and Net, never the sim.
- `gameplay/` — `Fighter` (state machine, public contract in its header;
  `Targeting` picks/cycles its target),
  `CombatSystem`, `MoveData`, projectiles, `CharacterDef`/`CharacterRegistry`,
  `FighterVisual` (placeholder primitives, read-only view of the fighter).
  Fighter/projectile visuals are `SmoothedVisual`s (presentation/view):
  top_level, blended between the last two sim ticks (motion smoothing; the
  engine's physics interpolation stays off). Anything framing an entity on
  screen reads `SmoothedVisual.render_transform_of(node)`.
  - `ai/CpuBrain`: the CPU opponent. Reads public fighter state behind a
    reaction delay and emits `InputFrame`s (no cheating, no fighter changes).
    Difficulty levels and every behavior knob live in `data/tuning/cpu.tres`
    (`Vector2` = weakest..strongest level, lerped per level).
- `presentation/` — match scene, arena, split-screen `ViewLayout` (2 side by side, 3-4 in a 2x2 grid),
  `FighterCamera`, HUD, VFX, pause menu. Observes signals only, through
  `MatchEventHub` (SPEC_ONLINE.md §9): the immediate stream (`fighter_event`,
  `fighter_state`, `director_event`; keyed by tick/sim_id/kind, muted during
  a rollback resim) drives VFX, SFX, shakes, flashes; the confirmed stream
  (`confirmed_event`; instant offline, `rollback_to`/`confirm_through`
  online) drives match flow, banners, results and `RunStats` (co-op
  per-player stats). Timer, enemies left, bars and the ki loop read state;
  only structural director signals (spawn/remove) are connected directly.
  - `audio/`: `Sfx` autoload (play by sound name, voice pool, keyed loops,
    menu focus blip) and `MatchSfx` (fighter events/states + director
    signals -> sounds). Mix volumes in `data/tuning/sfx.tres`; menu sounds
    play on the UI bus, the rest on SFX.
- `scenes/menus/`, `ui/` — main menu, unified lobby (`Lobby`, local and
  online; rules/data in `core/match/LobbyModel`), join-online screen (recent
  hosts), settings hub (`SettingsScreen`: LB/RB tabs Graphics / Audio /
  Controls / Online, pages in `scenes/menus/settings/`; display changes are
  debounced then confirmed with a revert countdown; also a pause-menu
  overlay with the Online page locked), controls rebinding (`ControlsScreen`,
  embedded as the Controls tab), results (online: rematch votes, lobby,
  save replay). `ui/`: `OptionSelector`, `NumberStepper`, `ConfirmPrompt`.

## Rules

- **No magic numbers.** Shared constants go in a tuning Resource
  (`core/tuning/*.gd` + `data/tuning/*.tres`); per-move numbers go in MoveData.
  New category: add a script, one `REGISTRY` line + var in `tuning_db.gd`, then
  `godot --headless --script res://tools/generate_tuning.gd` (`-- --force`
  overwrites ALL .tres with script defaults — avoid if values were hand-tuned).
- Movesets/characters are generated by `tools/generate_moves.gd`; edit that,
  then rerun it, rather than hand-editing `data/moves/*.tres`.
- Sound effects are sfxr sounds: `data/sfx/<name>.sfs` (sfxr.exe's own format,
  editable with `wine ~/Downloads/sfxr/sfxr.exe`) rendered to
  `assets/sfx/<name>.wav` by `godot --headless --script
  res://tools/generate_sfx.gd` (port of sfxr's synth in `tools/sfxr/`; writes
  missing .sfs from its PRESETS, `-- --force` overwrites them). Never
  hand-edit the .wav files; rerun the script, then `--import`.
- Gameplay runs only in `sim_tick` (never `_process`/`_physics_process`), must
  be deterministic, and every sim variable must round-trip through
  `save_state`/`load_state` (future rollback netcode).
- Sim code never calls libm-backed math (`sin`, `atan2`, `angle_to`,
  `rotated`, `Basis(axis, angle)`, `pow`...), the global RNG or the clock: use
  `DetMath` (`core/sim/det_math.gd`) and a seeded `RandomNumberGenerator`.
  `tests/determinism_lint_test` enforces it (`# det-ok: <reason>` to allow).
- Gameplay never polls `Input`; it reads `InputFrame`s. New modes = new
  `InputSource` + `MatchConfig` setup, not fighter changes.
- Presentation never writes gameplay state.

## Tools

`tools/coop_sim.tscn`: headless CPU-only co-op batches (offscreen rule off vs
on; clear rate, hits from outside the view cone, token leaks). Run with
`godot --headless res://tools/coop_sim.tscn -- runs=12 enemies=4
coop.melee_tokens_per_player=1` (any `coop.<prop>=<n>` overrides tuning).

`tools/net_bench.tscn`: headless rollback cost bench (SPEC_ONLINE.md §12).
CPU-only match, then mean/p50/p95/max of `step`, `save_state`, `load_state`,
snapshot `var_to_bytes`+hash and an N-tick rollback, the per-frame budget
estimate vs 8 ms, a determinism check (OK/MISMATCH, non-zero exit on
mismatch) and a `NET_BENCH ...` summary line; then (unless `driver=0`)
the same match through real `RollbackDriver`s over a `LoopbackNetwork`
(one peer per human, `latency= jitter= loss= delay=`), timing each peer's
`advance()` per rollback depth ("Full (driver)" = p95 of full-depth
rollback frames) and a `NET_BENCH_DRIVER ...` line. `godot --headless
res://tools/net_bench.tscn -- humans=2 enemies=6 [mode=coop|versus ticks=1800
warmup=600 rollback=8 seed=7 coop.field_cap=10]`; the field is humans +
enemies, clamped by `coop.field_cap`. Record results in SPEC_ONLINE.md §12.1.

`tools/replay_hash.tscn`: `-- replay=<file>` plays a replay headless, prints
`<tick> <hash>` per checkpoint, exits 1 on a mismatch (cross-OS determinism
check); `-- record=<file> seed=<n> mode=versus|coop ticks=<n>` records a
CPU-only match.

## Export

`export_presets.cfg` has "Linux" and "Windows Desktop" (x86_64, embedded pck,
excludes `tests/ tools/ docs/ *.md`) writing to `builds/` (gitignored). Needs
the 4.7.2 export templates (editor: Editor → Manage Export Templates →
Download, or install the 4.7.2 `.tpz` from godotengine.org), then
`mkdir -p builds/linux && godot --headless --export-release "Linux" builds/linux/god_hand_tenkaichi.x86_64`
(or `"Windows Desktop" builds/windows/god_hand_tenkaichi.exe`).

"Web" (offline only: no online/UPnP/Quit/window rows, see PlatformCaps)
exports single-threaded (`web_nothreads_*` templates, no COOP/COEP headers
needed) with the Compatibility renderer (`rendering_method.web`):
`mkdir -p builds/web && godot --headless --export-release "Web" builds/web/index.html`,
then serve `builds/web/` over HTTP (`python3 -m http.server`; `file://`
won't load) and open `http://localhost:8000/`: Godot needs a secure
context, which plain HTTP only is on `localhost`/`127.0.0.1` (not
`0.0.0.0` or a LAN IP; those need HTTPS). For other devices on the LAN:
`python3 tools/serve_web.py` (HTTPS on :8443 with a self-signed cert in
`builds/web-cert/`, accept the browser warning once; `--regen-cert` after
an IP change; also sends COOP/COEP). Online in the browser: `docs/web_online.md`.

## Design references

`docs/bt3_reference.md` and `docs/god_hand_reference.md` hold mechanics and
numbers from the two games' decompilations (converted to 60 Hz), with ideas
for steering toward each; `docs/reference_mechanics.md` compares them with
ours. Describe mechanics in our own words; never copy decomp code.

## Known gaps

Online 1v1, co-op and team versus / couch + online (milestones 2, 3, 5)
are implemented and tested headless, but not yet play-tested
Linux↔Windows over a real WAN; drop-in / reconnect is milestone 4
(SPEC_ONLINE.md §15). Headless tests
see real gamepads plugged into the machine (net_results_test swallows
real input events for that reason). The CPU only knows the moveset roles in `CharacterDef`
(string, heavies, supers), not character-specific tricks.
