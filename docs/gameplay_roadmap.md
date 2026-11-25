# Gameplay roadmap: conclusions from the second reference pass

Written 2026-11-15 from [bt3_sauce.md](bt3_sauce.md) and
[god_hand_sauce.md](god_hand_sauce.md), after the report "the game is okay
but gets boring quick": hits and movement lack weight, the CPU is not a fun
opponent, too little variety, the same plan always wins. All four were
named, across every mode.

**Revised the same day after phase 0.** The first version of this file
proposed rebuilding the fighter around "soft hitstun" (a BT3 stagger the
victim can guard out of). You approved it. Then I played scripted fights in
the BT3 port and the claim turned out to be false. This version replaces
that plan.

Status: proposal. Stage 0 done (2026-11-25); stage 1 implemented
(2026-11-25, waiting for your playtest: its gate); stages 2–5 not started. I still have not played our game; its numbers are read from
code and tuning files.

## Phase 0 result: the hitstun claim was wrong

Measured in the BT3 PC port with `tools/reference/bt3_script.py` (scripted
pads, no window; details in bt3_sauce.md "Measured in the port"):

- A jab's real stun is about **20–30 frames**, the same order as ours
  (20). The 48-frame stagger animation has an early exit.
- A chained string lands in full against a held guard; a restarted string
  is blocked. That is how our strings already work.
- Confirmed as extracted: 40000 health, string damage 300 / 300 / 300 /
  410 / 580, hits 10–16 frames apart.

Consequences:

- BT3 and our game do **not** differ in how light hits work. The first
  version's central argument for a rebuild ("the gap is structural") rested
  on that difference and falls with it.
- Reading matching code was not enough to know how the game plays. Every
  other BT3 rule we plan to copy gets a scripted test first (the tool makes
  that a 25-second run).
- The differences that survive are real but mostly **quantitative or
  additive**: they can be tried on the current fighter before deciding
  whether it needs replacing.

## Answer (revised): step back, but do not rebuild yet

- **Step back: yes.** Stop adding features; align what exists with the
  references' measured numbers and rules, and playtest each step.
- **Rebuild the fighter: not decided.** Stage 1 below runs on the current
  core. The rebuild question comes back at stage 2 with a concrete trigger:
  if adding the reaction table and follow-ups to `fighter.gd` (2791 lines)
  is fighting the code, we split it into actions and records then.
- **Keep** the director, input, rollback, online, co-op run logic, tests
  and tools in every case.

## What still separates us from the references

| Complaint | What the references do | What we do | Evidence |
|---|---|---|---|
| Hits and movement lack weight | BT3: no hitstop; jab shake 3 for 0.1 s and a 100-unit push, smash shake 5–7 for 0.3 s and a 1000–2000 blow-away with floor and wall crashes; the attacker lunges into each hit and stops on contact. Jabs start on frame 8–12; enders and smashes are stuck ~100 frames unless they land. A jab is 0.75% of health. God Hand: close camera, victim slow-motion, seven launch strengths, floaty fall. | Hitstop 4 vs 8, one knockback vector, one gravity. Jab 5f startup, 20 total, default recovery 12. A jab is 3% of health. | damage and string timing measured; shake, push, recoveries from data |
| Same plan always wins | BT3: guard is free against jabs but a charged smash is unblockable in the wrong pose or costs a full ki bar; the Z-counter only works on smashes and finishers; trades go to the higher priority; two strings meeting guard each other; smashes charge up to 4× faster as you land hits. God Hand: enemies start guarding after 1–4 hits (your answer), and only a slow guard break opens them. | Ki guard costs 4–5% of a bar, the Z-counter works on jabs, trades hit both, nothing changes during a fight. | data and code, **not yet played** |
| CPU is not a fun opponent | Authored per type: BT3 rule tables over a situation word, 32 personality profiles, weighted combo branches; God Hand hand-written dice per enemy type with circling / watching / hopping away, long telegraphs and recoveries, a level meter. | One parametric brain; difficulty = shorter reaction delay. | code |
| Too little variety | Situational: reaction of the victim, momentum, walls and floor, back hits; God Hand adds player-built strings. BT3's 161 characters share one moveset. | Few situations; roster by profiles (same method as BT3, fine). | data |

## Plan (revised)

Every item is tested in the reference first when a script can do it, then
implemented, then **played by you**. Sim rules as always: determinism lint,
rollback test, save/load round trip.

**Stage 0. Finish ground truth.** *(Done 2026-11-25.)*
- BT3 by script: a charged smash into each guard pose (plain / ki guard /
  unblockable / push-off and the ki actually paid); a jab against a smash
  (priority); Z-counter attempts against a jab and against a smash; smash
  charge time before and after a long string (momentum); what a blow-away
  into the floor and the ring edge does.
  **Done** (70 runs, `bt3_script.py --probe`; table in
  [bt3_sauce.md](bt3_sauce.md) "Second pass"):
  - Guard poses: as the data said, except a ki guard costs **about half a
    bar** (more for a full charge), not a full bar.
  - Jab vs smash: not a trade. A jab that lands first hurts the smasher,
    but the smash keeps going and lands in full.
  - Z-counter: works against a smash (2–8 frames before the hit, free),
    **never against a jab** (the same press is a plain guard).
  - Momentum: real but small, 1.3–1.4× faster charge after 4–8 hits,
    fading within about a second.
  - Blow-away: floor crashes and a stage-object crash each add 500 (1.25%
    of health); no run reached the ring edge.
- A frame-data sheet tool for our moves (startup, active, recovery,
  advantage on hit and on guard, damage %, push), to compare on paper.
  **Done:** `tools/frame_data_sheet.tscn`, output in
  [frame_data.md](frame_data.md), formula checked against the sim by
  `tests/frame_data_test`.
- God Hand: the third pass (2026-11-23, God Hand: Rearmed + the retail
  ELF) answered the dodges and the crowd rules from code
  ([god_hand_reference.md](god_hand_reference.md)). Still open: hitstop
  length (two runtime words) and per-move cancel windows (motion data);
  Rearmed's test mode could measure both like `bt3_script.py` does.
  **Done** (2026-11-25, `tools/reference/ghr_script.py` on the native
  Linux AppImage from your F5 save in the first fight, Hard; table in
  [god_hand_reference.md](god_hand_reference.md) "Measured in Rearmed"):
  - Hitstop: **none** on ordinary hits (punches, △ heavy, × kick, hits
    on Gene); both length words are 0 mid-fight. God Hand's weight comes
    from the animation slowing after contact and instant reactions, not a
    freeze. Special hits (roulette, God Hand mode) untested.
  - Cancel window, □ punch 1 → 2: chains from punch 1's frame 12 to about
    frame 24–28 of 34, earlier presses buffered, **also on a whiff**. The
    other links can be timed the same way when stage 1 needs them.

**Stage 1. Numbers pass on the current fighter** (one branch, one playtest).
- Damage scale: about 0.75% per jab, ~5% per full string; round timer and
  best-of retuned. *(Longer rounds: approved.)*
- Frame data from BT3's tables through `tools/generate_moves.gd`: jab
  startup ~8, enders and smashes long with on-hit cancels only.
- Impact: no hitstop on lights; per-move camera shake, approach speed and
  push with BT3's ratios; much larger travel on smashes.
- Whichever of these stage 0 confirms: priority trades, mid-string
  auto-guard, Z-counter on smashes and finishers instead of jabs, ki guard
  at a real price.
  *Stage 0 confirmed:* Z-counter on smashes only (not jabs); ki guard at
  about half a bar, scaled by charge (ours: 15% uncharged, rising with
  the charge, and a full charge crashes any guard, which BT3's full
  smashes never did: they were plain, ki, push-off or unblockable by
  pose); a smash under way not interrupted
  by rush hits (closer to armor against lights than to a priority trade);
  momentum only as a small, short charge-speed bonus. Not tested yet:
  mid-string auto-guard (two strings meeting) and dash smash priority.
- **Gate:** does it feel better? Which complaint is still there?

  **Implemented 2026-11-25** (branch `worktree-roadmap-stage1`; numbers in
  [frame_data.md](frame_data.md); rules held by `tests/stage1_rules_test`):
  - Damage ×0.25 (`DAMAGE_SCALE` in `tools/generate_moves.gd`): jab 0.75%,
    full string 5%, full smash ~3%. Defaults now one round of 180 s
    (options 120 / 180 / ∞; the lobby still picks 1–5 rounds): CPU vs CPU
    rounds went from 25–70 s to ~100–240 s with no timer.
  - String: jab hits on frame 8, chained hits 9–19 frames apart, each
    inside the previous stun. Ender recovery 70, smashes 44, finishers ~40,
    tapped heavies 34–42; their follow-ups need a clean **hit**
    (`cancel_requires_hit` no longer opens on a block). Super cancels still
    work on block (2 bars).
  - Impact: no hitstop on lights or the ender (heavies keep 8); per-move
    shake (`MoveData.shake`, growing with the charge); jab push 1.0, ender
    7.0, smashes 13 m/s (~2× the travel); BT3 approach (rush 1 at 9.5 m/s,
    later steps 5.5, walk 6) that stops when the hitbox reaches the target.
  - Rules: Z-counter only on `MoveData.z_counterable` moves (smashes,
    finishers, heavies, dash attack; the CPU follows); ki guard 45 per hit,
    smashes 40 → 56 at full; full charge no longer crashes a guard
    (`FighterTuning.charge_breaks_guard`, off); smashes absorb 4 light hits
    while under way; momentum (up to 1.4× charge speed right after landed
    hits, gone about 1.5 s later); no ki for being hit. Charged body blow
    stun 50–80 (was 36–60) with on-hit follow-ups, so the stun converter
    survives its longer recovery.
  - Not done here: charge-dependent guard results per pose (BT3's neutral
    smash is plain in mid guard, a full side smash goes through both stick
    poses: we keep one result per pose), priority trades beyond smash
    armor, mid-string auto-guard and dash smash priority (untested in BT3),
    co-op enemy health (waves now take ~4× longer too).

**Stage 2. Reactions and states.** Reaction table (heavy stagger, bounce,
blow-away with crashes, stun), follow-ups by the victim's reaction,
momentum, then God Hand's converters: guard break, floaty juggles, dizzy →
pummel (a decaying stun gauge: 200, 5 s dizzy), downed → stomp, victim
slow-motion. God Hand's dodge split goes here too: short invulnerable
starts (sway 10f, back-flip 24f), a duck that only removes the upper
hurtbox and loses to **low** attacks, a near-miss reward and a duck
counter in place of the perfect-dodge freeze. *Decide here whether the
fighter is rebuilt as actions + attack records + reaction table (shape in
the appendix).*

**Stage 3. Opponents.** CPU as situation word → weighted rules →
personalities, tells and level-scaled recoveries, a level meter; co-op
enemies as a few authored types, placed by God Hand's crowd rules
(distance rank → approach ring, flankers walk to the front, back-hold
cones by level, no attacks on a grabbed player; reference "Enemies as a
group").

**Stage 4. Variety.** String loadouts *(approved)*, skill flags per
character.

*String loadouts* (God Hand's technique slots,
[god_hand_sauce.md](god_hand_sauce.md) §4): each player builds their own
LIGHT string from a pool of techniques, so variety comes per player rather
than per character.
- **What blocks it now:** the string is written into the moves. Each step's
  `cancel_into` names the next step and that position's finisher
  (`jab1 → jab2 → hook → kick → ender`); `CharacterDef.light_string` is
  only read for its first entry. Nothing can be reordered.
- **Chain by slot, not by move** (the one real core change): the fighter
  keeps a `string_step` (sim state, in `save_state`); LIGHT in the cancel
  window starts the move in slot `step + 1`. Timing and cancel windows stay
  per move; `cancel_into` stays for links outside the string (enders,
  follow-ups on hit). Decide whether the HEAVY finisher keeps following the
  position (BT3, as now) or becomes a slot too (God Hand: forward / back +
  button are slots as well).
- **The loadout is a player choice, not character data:** it lives in
  `PlayerSlotConfig`, is checked by `MatchConfig.from_dict` and carried by
  `to_dict`, so replays and online peers get it with no extra work. It is
  fixed for the match, so it stays out of `save_state`. Saved loadouts per
  character and binding profile go in `user://`.
- **Technique pool:** moves anyone can slot, each with a slot type
  (opener, string, ender, finisher, launcher). `tools/generate_moves.gd`
  scales every pool move per roster profile offline, as it already does
  for the Brawler's moves, so Titan's version is slower and stronger.
- **Editor rules:** slot types (only an ender in the last slot, launchers
  at the end); a true-combo / gap readout per link (the next move's startup
  against the previous one's hitstun). In God Hand a gap is part of the
  choice, while BT3 strings always land: decide which way we lean.
  Infinite loops are already stopped by `loop_group`.
- **CPU:** `CpuBrain` reads `def.light_string` (reach, string length);
  it reads the fighter's active string instead and then plays any loadout.
- **UI:** a loadout editor from the lobby card (slots with startup, damage
  and true-combo / gap marks); online it travels with the seat rows.
- **Order:** after stage 2. If the fighter is rebuilt there, strings must
  be built as lists of slots (see the appendix); then this stage is mostly
  data, UI and generator work. Done earlier, a first step that changes
  nothing in play: chain by slot with today's string as the default
  loadout, plus a save/load round-trip test.

**Stage 5. Custom characters (mods)** *(proposal, 2026-11-24)*: players
add characters from files, as MUGEN does, without rebuilding the game.
What already makes it practical:
- Gameplay does not depend on what is shown. A move is data (`MoveData`:
  frames, a hitbox in the fighter's own space, damage, guard results,
  cancels), not boxes drawn on animation frames, so a custom look cannot
  break determinism or rollback.
- A character is already data: `CharacterDef` + its `MoveData` + stat
  overrides. The CPU knows only moveset roles, so it plays a custom
  character without extra work.
- The body format suits modders: `FighterModel` loads a `.glb` with one
  rigid mesh per rig joint, named after the joint, with palette slots in
  UV.x. Poses come from code (`FighterVisual`), so a custom model needs
  **no animations of its own**: a Blender file with the right part names
  is enough. Godot loads a `.glb` at runtime with `GLTFDocument`, the web
  build included.

What has to be built:
- **A safe file format:** never load `.tres` from users, because a
  Resource can embed a script that then runs on the player's machine.
  Use JSON for the character and its moves, turned into `CharacterDef` /
  `MoveData` with every field checked (as `MatchConfig.from_dict` does),
  plus the `.glb` and optional sfxr `.sfs` sounds (tiny text files).
- **Finding characters:** `CharacterRegistry.IDS` is a fixed list; scan
  `res://data/characters/` plus `user://characters/<id>/`.
- **A model per character:** today every fighter uses one model
  (`Tuning.vfx.fighter_model_path`); `CharacterDef` gets its own path,
  falling back to the shared model, then to the primitives. A missing part
  falls back to the default part.
- **New poses** a custom move needs are data too (joint rotations, the
  same shape as `FighterVisual.POSES`), falling back to a generic pose.
- **Online and replays:** `ContentHash` already covers moves and
  characters, so mismatched files are already caught. Either refuse the
  match, or send the missing character over the bulk channel (JSON is
  small; a `.glb` can be a few MB). Replays name the character's hash.
- **Web:** no folder to drop files into: upload through a browser file
  picker, or bundled packs.
- **An authoring kit:** one example character, the Blender template
  (`tools/blender/build_fighter.py` as the reference for part names and
  palette slots), the list of poses and a guide to the move fields.
  `tools/matchup_sim.tscn` can double as a check that flags a broken
  character.
- **Limit:** behaviour is what `MoveData` can express. MUGEN-style
  scripts (its state files) are out: `JsRuntime` exists, but scripts
  would call libm math (non-deterministic across platforms), need their
  state saved for every rollback and cost time on every resimulated
  frame. Mods get more power as the move vocabulary grows, which the
  built-in roster needs anyway.
- **Order:** (1) data-only characters on the shared model, with colours
  and proportions; (2) a `.glb` and poses per character; (3) sending them
  online; scripting never. With stage 4, a mod can also be a single
  technique added to the pool rather than a whole character.

## Your decisions so far

| Question | Your answer | Now |
|---|---|---|
| Soft hitstun | approved | **withdrawn by me**: BT3 does not work that way (phase 0) |
| Longer rounds | approved | done (stage 1): one 180 s round by default |
| String loadouts | yes | stands (stage 4; design written 2026-11-24) |
| (2026-11-24) Custom characters from files, like MUGEN | add to the roadmap | stage 5, proposal |
| Co-op and online stay on the old core until a switch-over | yes | moot for now: stage 1 changes the shared core, so every mode gets it; `matchup_sim` and `coop_sim` rerun after |
| I may drive the games | yes | done for BT3 (headless); not yet for God Hand |
| God Hand enemies guard after how many hits | random, 1 to 4 | recorded in god_hand_sauce.md |
| (2026-11-23) Y mid-string | BT3 finisher by string position; fwd + Y = upper hook, back + Y = sweep | done |
| Neutral Y in close range | melee heavy (body blow, stagger) + fwd / back variants; ki blast out of range | done |
| Holding Y | BT3 charged finisher / charged heavy / charged ki blast | done |
| When the victim falls | BT3 reactions: launchers, sweeps, smashes ≥30%, full-string finisher, throws | done |
| X string length | 5 (BT3 ender) | done |
| Frame data | structure first, BT3 frame-data pass later (stage 1) | stands |
| Juggle | God Hand floaty fall + ground juggle hits | done |
| After a tapped Y finisher | string ends; follow-ups only on hit | done |

Earlier decisions stage 1 would reverse if stage 0 confirms them: guard
vanish on string openers (→ on smashes and finishers), hitstop 4 / 8 on
normals (→ none on lights), jab timing and damage, ki guard price, +3 ki
per hit taken, both-hit trades. The 2-bar vanish escape from hitstun is
**no longer proposed for removal**: with real hitstun it keeps its job.

## Not done

- **God Hand:** scripted runs work since 2026-11-25
  (`tools/reference/ghr_script.py`, one save state in the first fight).
  Still open there: the other combo links' cancel windows, whether
  counter hits stagger harder, and whether special hits (roulette, God
  Hand mode) set a hitstop. Which dodge beats which attack is answered in
  code.
- BT3: the rules in stage 0 are done (2026-11-25); still unscripted are
  two strings meeting, dash smash priority, the paid teleport counter, a
  whiffed smash's recovery and a blow-away into the ring edge.
- Our game was not run (the frame-data sheet reads data; its advantage
  formula is checked against the headless sim only).

## Appendix: shape of a rebuilt fighter core (only if stage 2 calls for it)

Borrowed from how BT3 is organised (structure, not code), under our rules
(`sim_tick` only, `DetMath`, everything in `save_state`):

- **Actions** with enter / run / decide / leave, each naming which input
  groups are live, instead of one state machine.
- **Attack records** (the next `MoveData`): damage, guard damage, ki gain,
  momentum gain, approach speed, push on hit and guard, launch angles,
  shake on hit and guard, priority, guard result per pose, the reaction it
  causes per victim state, flags (Z-counterable, turns the victim, ignores
  armour).
- **A reaction table**: reaction id → action, with its rules in one place
  (mash speeds it up, counts toward anti-loop, stun length, crashes).
- **Follow-up tables** keyed by the victim's reaction.
- **Strings as lists of slots** (a step counter and the slot's record),
  not moves that name their successor, so stage 4's loadouts and stage 5's
  custom characters need no further core change.
- Frame data stays numbers in the record (we have no skeletal animation).
- A per-fighter time scale in the sim for victim slow-motion.
- The `Fighter` public contract is kept so CPU, HUD, VFX and camera keep
  working. Cross-cutting, so it would need `docs/SPEC_COMBAT.md` first.
