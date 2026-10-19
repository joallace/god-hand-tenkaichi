# Co-op mode & generic teams — spec

Status: agreed in interview, 2026-10-18. Nothing implemented yet. Numbers
marked *(tunable)* are starting picks that will live in tuning Resources,
not decisions.

## 1. Goal

A God Hand-flavoured mode: 1–2 local humans (plus an optional CPU ally) fight
a crowd of CPU enemies together. This work also generalises the whole sim from
"two fighters, each with one `opponent`" to **teams of N**, so future online
play can have n-vs-n with humans on both sides. Versus 1v1 is just two teams
of one, and it must keep playing the same, apart from the deliberate
per-fighter hitstop change (§4.3).

Non-goals for this project: online play, a shipped local 2v2 *versus* mode
(the team model makes it possible later), hand-authored stages/levels,
grunt-only enemy types, CPU character-specific tricks.

## 2. Mode overview

| | Brawl | Waves |
|---|---|---|
| Enemies | `enemy_count` total, at most `field_cap` on the field, the rest queued | `wave_count` waves (or endless), each with its own enemy count |
| Win | every enemy KO'd | last wave cleared (endless: no win, the run goes until the team wipes) |
| Lose | whole human team downed or out, or time limit reached | same |
| Between | — | breather (§6.2) |

- **One run, no Bo3.** The run ends on clear or wipe. The timer setting is a
  limit for the whole run (infinite by default).
- **Players:** 1–2 local humans on team 0. A solo human can add a CPU ally
  (team 0, has its own CPU level). Two humans can add one too, within the
  field cap.
- **Enemies:** full `Fighter`s driven by `CpuBrain` (same characters and
  movesets as versus). No separate grunt class.
- **Field cap:** 8 fighters in total on the field *(tunable,
  `coop.field_cap`)*. Humans and the ally count toward it. Extra enemies wait
  in a queue and enter as others are KO'd.
- **Scaling:** no hidden scaling. The setup screen picks the count, CPU level
  and roster.

## 3. Team model (core refactor)

### 3.1 Data

- `PlayerSlotConfig.team: int` (default `slot`, so existing 1v1 configs keep
  working).
- `MatchConfig.Mode` gains `COOP`. New `CoopConfig` resource referenced from
  `MatchConfig` (`coop: CoopConfig`, null outside co-op), holding: `structure`
  (BRAWL/WAVES), `enemy_count`, `waves: Array[WaveConfig]` / `endless`,
  `enemy_level`, `enemy_roster` (RANDOM or a character id), `ally` (none / CPU
  + level), `friendly_fire: bool`, and the time limit (reuses
  `round_time_seconds`).
- `WaveConfig`: `count`, optional level/roster override.
- Enemy slots are **not** in `players`. The director creates them from
  `CoopConfig` through the factory (§8). Slot ids keep counting up after the
  config slots and are never reused within a run (stable ids for
  HUD/events/rollback).

### 3.2 Fighter

- `opponent` is replaced by **`target: Fighter`** (may be null), plus
  `team: int`. Keep a read-only `opponent` getter that returns `target` during
  the migration so presentation keeps working, then remove it.
- Everything that used `opponent` (facing, fighter-space stick, attack
  tracking, sidesteps, teleport placement, throws, lunges, guard-from-behind
  checks) uses `target`. With a null target the fighter keeps its current
  facing, and the stick is relative to its own forward vector.
- New public API: `is_downed()`, `is_out()`, `is_targetable()`
  (false while downed/out, vanished, entering, or KO'd), `hitstop_left()`.
- Add the new vars to the header contract and to `save_state`/`load_state`.

### 3.3 Targeting (humans)

- **Auto:** when the target is null, dies, becomes untargetable, or
  `retarget_check_frames` passes *(tunable)*, pick the best enemy by score:
  angle from the fighter's forward vector, distance, and a bonus for enemies
  currently attacking this fighter. Hysteresis keeps the current target
  unless another one beats it by a margin.
- **Manual:** new `Btn.TARGET` action, default **LB**, rebindable. A tap
  cycles to the next enemy by angle around the fighter. The left stick's X
  when tapped picks the direction (neutral = clockwise). A manual pick
  **sticks** until that enemy dies or becomes untargetable, or TARGET is
  tapped again.
- Selection runs in `sim_tick` from `InputFrame`s and positions only
  (deterministic and saved).
- Keyboard layouts get a TARGET key (next free key in each layout).

### 3.4 Target choice (CPU, both sides)

The enemy brain scores humans/allies by distance, who hit it last, whether a
token on that player is free, and a bias toward low HP. The choice is
**sticky** for at least `cpu.target_min_hold_frames` *(tunable)*. The brain
never targets a downed or out player. The CPU ally uses the same scoring
against enemies.

## 4. Combat rules in crowds

### 4.1 Attack tokens (director-level, deterministic)

Not in God Hand's decomp: the matched `cEmManage` only has a short global
grab lock (`plCatched`/`slotWait`, refreshed every frame while an enemy holds
the player), so this is our own design built on top of that idea.

- New `EncounterDirector` (sim object owned by `MatchDirector`, saved and
  loaded with it) keeps, **per human/ally fighter**:
  - `melee_tokens` = `coop.melee_tokens_per_player` *(tunable, start 2)*
  - `ranged_tokens` = `coop.ranged_tokens_per_player` *(start 1)*: ki blasts,
    beams, supers, ultimates, air ki blasts
  - `grab_lock`: at most one throw attempt or hold on that player at a time
    (like God Hand's `plCatched`).
- An enemy brain must hold the right token for its target before pressing an
  attack. The token comes back when the move ends, the holder is
  hit/stunned/KO'd, it changes target, or after `token_timeout_frames`
  *(tunable)* (so a token holder that hangs back doesn't block the queue).
  Grant order is deterministic: requests sorted by (wait time desc, slot asc).
- Tokenless enemies keep to mid range: circling, guarding, charging ki,
  taunting (taunt doesn't need a token), and walking for spacing. They still
  **defend** normally (guard, dodge, vanish escape) without tokens.
- **No visual tell** when a token is granted. Players read the animations as
  in versus.
- Tokens apply only to the CPU **enemy** team attacking humans/allies. The
  ally and humans are unrestricted. In a future n-vs-n with humans on both
  sides, tokens are off (a `MatchConfig` flag).
- Optional tuning toggle, off by default: `coop.offscreen_attack_rule`
  (an enemy outside the target's sim-computed view cone can't start an
  attack). The cone comes from fighter positions and facing, never from the
  real camera.

### 4.2 Friendly fire

- Off by default; a setup toggle turns it on. Off = hitboxes skip fighters
  on the attacker's team (melee, projectiles, beams). Enemies never hurt each
  other unless the toggle is on. Bodies always collide.
- `CombatSystem` tests the team filter where it currently checks
  `victim == hb.attacker`.

### 4.3 Hitstop: per fighter (all modes)

- `MatchDirector.hitstop` becomes per entity: `Fighter.hitstop`, and the
  projectile gets it from its owner. A contact freezes **only the attacker,
  the victim and the hitting entity**. Everyone else keeps simulating.
- `request_hitstop(frames)` becomes `request_hitstop(entities, frames)`.
- **Global freezes stay global:** the ultimate freeze, the counter-guard
  freeze and the push-stop freeze still stop everyone (a director-level
  `world_freeze`).
- `CpuBrain`'s `_clock` follows **its own fighter's** hitstop instead of
  `director.hitstop`.
- The round timer pauses only during `world_freeze`.
- This also changes 1v1 versus. In 1v1 the result is the same except
  projectiles (they no longer freeze for hits they aren't part of). Tests
  must cover it.

### 4.4 Combos, scaling, anti-loop

- Combo scaling and the anti-loop/relaunch counters move from **the
  attacker's** count to **the victim's** combo (hits taken in the current
  juggle, from any attacker), so two players juggling one enemy scale
  together. No infinite tag loops.
- Each player's on-screen `combo_changed` still counts only their own hits.
- Teleport combo extension (max 2 per combo) counts per attacker.

### 4.5 Locks: throws and vanish battles

- Third parties **can** interrupt. A hit from outside on either participant
  breaks the lock and frees both: the hit fighter takes the hit normally, and
  the other returns to neutral (thrown → tech-style recovery, a vanish-battle
  partner reappears). The interrupter gets combo credit only for its own hit.
- Lock participants keep their tokens/grab lock until the lock ends.
- Locked players stay valid targets for enemies (with tokens). Your partner
  can rescue you, and an enemy can break your throw on another enemy.
- Every break path must leave both fighters in a valid state. Add a test per
  lock type.

### 4.6 Teleport and vanish placement

- Teleport chase reappears around **the current target** (the last enemy
  you hit). Vanish escape reappears around **whoever hit you**. The left
  stick still picks the side.
- Destination resolve: if the spot is inside another fighter's body radius
  or outside the ring, try alternative angles in a fixed order, then fall
  back to pushing it out. Deterministic.

### 4.7 Ultimate and supers

- Ultimate: the whole world freezes (`world_freeze`). The cinematic plays on
  the user's view. Other local views show the freeze plus a "P1 ULTIMATE"
  banner.
- **Beams and the ultimate beam pierce:** they hit every eligible fighter in
  their path (one hit per fighter per activation, as now).
- **Ki blasts, air ki blasts and rush supers** hit only their first victim.

### 4.8 Guard

Unchanged: guard fails from behind, by design (positioning and dodging
matter). Tokens limit how often you get hit from behind.

## 5. Downed, revive, KO

### 5.1 Humans and the CPU ally

- At 0 HP a team-0 fighter enters `DOWNED` (new state): lying, intangible,
  not targetable, no tokens assigned to it.
- **Revive:** a teammate within `coop.revive_range` *(tunable)* holds
  **TAUNT** (context-sensitive: TAUNT near a downed ally revives instead of
  taunting) for `coop.revive_frames` *(start 120)*. Taking a hit or letting go
  resets progress. Revived at `coop.revive_health_ratio` *(start 0.3)* HP and
  0 ki, with `wakeup` invulnerability.
- **Bleed-out:** after `coop.bleed_out_frames` *(start 900 = 15 s)* without
  a revive, the fighter is **OUT**: in waves, until the next wave break (which
  revives them); in brawl, for the rest of the run.
- The CPU ally revives humans: its brain treats a downed teammate as a
  high-priority goal when no enemy holds a melee token on it.
- **Wipe** = no team-0 fighter left standing (downed or out) → run lost.

### 5.2 Enemies

Enemy KO is final. The fighter plays its KO, fades after
`coop.enemy_fade_frames` *(start 120)*, is removed through the factory, and
frees its field slot for the queue. Enemies never revive each other.

## 6. Flow

### 6.1 Spawning and entry

- Initial field: humans/ally at fixed positions near the centre. Enemies
  fill up to `field_cap`.
- Each new enemy appears at the **ring-edge point farthest from the human
  team** (angular spread so simultaneous spawns don't stack), with a
  BT-style reappear effect, and spends `coop.entry_frames` *(start 30)*
  intangible and unable to attack.
- Queue refill: when a slot frees, the next queued enemy enters after
  `coop.refill_delay_frames` *(tunable)*.

### 6.2 Waves

- Wave cleared → breather of `coop.wave_break_frames` *(start 180)* with an
  announcer "WAVE N" banner. Downed and out players revive at
  `revive_health_ratio`, and everyone gets `wave_heal_ratio` HP and
  `wave_ki_refill` ki *(tunable)*. Then the next wave enters (§6.1).
- Endless: wave n's count/level follow a curve in `coop.tres`.

### 6.3 Pause

Either player pauses everything (as in versus). The pause menu shows who
paused and adds "Restart run".

## 7. Presentation

- **Views:** split screen with one lock-on `FighterCamera` per local human
  (reuse `ViewLayout`). The camera frames its fighter and their **current
  target** (null target → keep its current yaw behind the fighter). A solo
  human gets a single view.
- **HUD (per view):** own HP/ki, the current target's full HP/ki bar, small
  world-space HP pips over every enemy, and screen-edge arrows for off-screen
  enemies (no token-state colouring, matching "no tell"). Partner HP/ki shown
  small. Downed: revive-progress ring on the downed ally plus a bleed-out
  timer.
- **Global HUD:** run timer (if limited), wave counter / enemies left.
- `MatchEventHub` and `VfxManager` resolve the "other fighter" from event
  payload slots (`attacker_slot`, `target_slot`) instead of `opponent`.
- Sfx: new names for revive start/complete, downed, out, wave start/clear,
  enemy entry (sfxr presets in `tools/generate_sfx.gd`).

## 8. Dynamic spawning and the entity factory (rollback)

The chosen approach is dynamic spawning, which also closes the known gap that
`load_state` doesn't rebuild spawned projectiles/beams.

- **`EntityFactory`** (core/sim): makes any sim entity from
  `{type: StringName, id: int, init: Dictionary}`. Types: `fighter` (init:
  slot, team, character_id, input kind/level), `ki_blast`, `beam`. Each
  spawnable class provides `spawn_desc() -> Dictionary`.
- Every sim entity gets a stable `sim_id` from a director counter (saved).
- `MatchDirector.save_state` stores the **live entity list** (descs plus
  per-entity state) and the id counter. `load_state` diffs against the live
  set: free entities that shouldn't exist, create missing ones through the
  factory, then load each entity's state. Order is by `sim_id` (deterministic
  tick and combat order).
- Fighters and input sources: an enemy's `CpuInput` is created and freed
  with its fighter, and its state is saved with the entity.
- Presentation subscribes to new director signals
  `entity_spawned(e)` / `entity_removed(e)`, emitted after a load too
  (HUD pips, MatchEventHub watch, visuals).
- Test: save mid-wave with live projectiles, run K ticks, load, re-run K
  ticks → identical state hash.

## 9. Setup screen (join screen, COOP)

Main menu entry "Co-op". Each human joins as in versus. Rows (left/right to
change):

1. Character (per human)
2. Mode: Brawl / Waves
3. Enemies: count (brawl total; waves = per wave)
4. Waves: 1..N / Endless (waves only)
5. Enemy level (the existing 8 CPU levels)
6. Enemy roster: Random / a specific character
7. Ally: None / CPU (+ ally level and character rows when CPU)
8. Friendly fire: Off / On
9. Time limit: ∞ / values

Defaults come from `coop.tres`. The last setup is remembered for "Retry".

## 10. Results

Team result (cleared / wiped, waves cleared, time), then per player: KOs,
damage dealt, best combo, revives given, perfect dodges. Buttons: Retry
(same setup), Change setup, Main menu. Stats gathered by a presentation-side
listener on events (not sim state).

## 11. Tuning

New `CoopTuning` (`core/tuning/coop_tuning.gd`, `data/tuning/coop.tres`,
one REGISTRY line, generate without `--force`): field_cap, token counts,
token_timeout_frames, offscreen_attack_rule, revive_range/frames/health_ratio,
bleed_out_frames, enemy_fade_frames, entry_frames, refill_delay_frames,
wave_break_frames, wave_heal_ratio, wave_ki_refill, endless curves, setup
defaults, retarget_check_frames, target score weights.
`ArenaTuning`: `radius_per_extra_fighter` (or a co-op radius curve). The ring
grows with the planned max field size; visuals scale with it.
`CpuTuning`: target_min_hold_frames, threat-score weights, tokenless-behaviour
weights (circle/guard/charge/taunt).

## 12. Milestones

1. **Teams refactor.** `team`, `target`, team-aware combat/KO/win logic,
   per-fighter hitstop plus world freeze, victim-side combo scaling, the
   `opponent` shim removed from presentation, TARGET input. Versus is
   unchanged apart from §4.3, and every existing test passes.
2. **Entity factory and dynamic spawning** (§8), with the rollback
   round-trip test. Also fixes projectile load_state.
3. **Brawl co-op.** CoopConfig, setup rows, EncounterDirector tokens and
   grab lock, CPU target choice and tokenless behaviour, DOWNED/revive/OUT,
   lock interrupts, piercing beams, arena scaling, HUD, edge arrows, spawn
   entry.
4. **Waves.** Wave flow, breather, endless curve.
5. **Polish.** CPU ally (incl. revives), results screen, sfx, tuning pass,
   offscreen rule experiment.

## 13. Tests to add

- Team filter: friendly fire off/on for melee, blast, beam.
- Per-fighter hitstop: a bystander keeps moving during another pair's
  hitstop; a world freeze stops all.
- Token invariants: never more than K melee and 1 ranged per player;
  released on hit/KO/timeout; deterministic grant order.
- Grab lock: a second enemy can't throw a held player.
- Each lock break: throw and vanish battle interrupted by a third party →
  both fighters valid.
- Targeting: auto-retarget on death; manual pick sticks; cycle order.
- Victim combo scaling across two attackers.
- Beam pierces 3 enemies; ki blast stops at the first.
- Downed → revive (interrupted, completed), bleed-out → out, wipe ends the
  run, a wave break revives.
- Entity factory save/load round-trip (§8).
- 1v1 regression: an existing versus scenario replays identically apart
  from the documented projectile-hitstop change.

## 14. Risks and open questions

- **Perf:** 8 Fighters + brains + split screen. Profile in M3; the field cap
  is tunable.
- **CpuBrain assumptions:** it was written for one opponent (threat
  detection, punishes). It must look at all threats, not just its target
  (e.g. defend against a non-target's beam). Expect the biggest AI changes
  here.
- **Readability:** with no telegraph and guard failing from behind, playtest
  whether 2 melee tokens is too many for a solo player. The token count and
  the offscreen rule are the knobs.
- **Stick space with a target swap:** "+Y = toward target" changes direction
  when the target changes mid-input. Retargeting should not happen in the
  middle of a dodge flick or a heavy's latched stick.
- **Camera with far targets:** the lock-on camera distance grows with
  separation. Clamp or soften framing when the target is across the ring.
- **Future n-vs-n online:** tokens off, the revive rules apply to every
  team, and the factory is a prerequisite for rollback. Nothing here should
  assume "team 0 = humans" outside co-op setup code.
