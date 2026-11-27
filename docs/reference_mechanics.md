# Reference mechanics: God Hand & Budokai Tenkaichi 3 vs. us

Research notes from reading the two community decompilations (2026-10-18):

- **BT3** — https://github.com/z3xox/Tenkaichi3Decomp (working PC port; game
  logic largely matched, with system docs under `docs/systems/`).
- **God Hand** — https://github.com/LucasPicoli/god-hand-decomp (~47% code
  matched; the player dodge/cancel dispatcher is still unmatched asm).

Full per-game notes, with "steer toward this game" idea lists:
[bt3_reference.md](bt3_reference.md) and
[god_hand_reference.md](god_hand_reference.md).

**Second pass (2026-11-15):** why the two games stay fun, BT3's real
per-move tables, and what follows for us are in
[bt3_sauce.md](bt3_sauce.md), [god_hand_sauce.md](god_hand_sauce.md) and
[gameplay_roadmap.md](gameplay_roadmap.md). Where they disagree with this
file, they are newer: BT3's Z-counter only works against smashes and
finishers (never rush punches), a restarted string is blockable while a
chained one is not (measured), and its ki charge is fast (full gauge in ~4 s for most characters).

**Third pass (2026-11-23), God Hand only:** the God Hand: Rearmed
recompilation (https://github.com/God-Hand-Rearmed/God-Hand-Rearmed), its
authors' notes, the updated decomp and the retail ELF opened the player's
input, dodge and cancel code and the enemies' group rules. Results in
[god_hand_reference.md](god_hand_reference.md) (sections "Controls",
"Dodges: read in code", "Enemies as a group"); the God Hand cells below
are updated from it.

Only *mechanics and numbers* are recorded here, in our own words. Never copy
code from either repo into this project (game code belongs to the rights
holders; the BT3 port code is AGPL).

## Unit conversions

Both games simulate at **30 Hz**; we run at 60 Hz. All numbers below are
already converted to **60 Hz frames** unless marked `@30`.

- Frame counts and windows: ×2. Per-frame rates/speeds: ÷2.
- BT3 speeds are authored in km/h (÷3.6 = units/s). BT3 gauges: HP 10000 per
  bar; ki 0..100000 = 5 bars of 20000 (same 5-bar shape as ours).
- God Hand units are ~1 m (camera look height 1.06, grab range 3.0).
- A lot of per-move timing (startup/active/cancel frames, damage, push) is in
  **disc data**, not code, in both games. Those gaps are listed in
  [What still needs PCSX2](#what-still-needs-pcsx2).

## Side-by-side

| Mechanic | BT3 | God Hand | Us now |
|---|---|---|---|
| Hitstop on normal melee | **none** — camera shake per hit sells impact | global freeze (hit tests, player and enemy updates wait); two lengths (Gene hits / is hit) are runtime data, still unread (measured 2026-11-25: none on ordinary hits) | ~~4 light / 8 heavy~~ → **stage 1:** none on lights (and the ender), 8 on heavies, per entity; per-move camera shake (`MoveData.shake`, growing with the charge) |
| Z-counter / guard vanish | guard **press** opens 8f window (6f <70% HP, 4f <30%); re-press during it = ~58f lockout (anti-mash); **first hit of an attack only**; 1 bar; no ki → free sidestep | — | ~~guard held 1..6f, any melee hit, 2 bars~~ → **done:** press window 8/6/4f by HP, 60f mash lockout, ~~string openers only~~ → **stage 1:** smashes, finishers, heavies and the dash attack only (`MoveData.z_counterable`; string hits are guarded), 1 bar |
| After a paid vanish | forced counter-attack; opponent can Z-counter it back (unlimited duel) | — | ping-pong duel with shrinking window; ends with positions only |
| Escape from mid-combo | not possible (mid-string hits undodgeable) — anti-loop rule instead | mash-out of grabs | vanish escape from hitstun, 2 bars (approved design) |
| Dodge invuln | vanishing step: invuln for the whole ~14f burst; dash steps: first 20% | **set once at the start**: sway 10f, back-flip 24f; **duck none**: head/chest hurt spheres off ~18f, low attacks still hit; dash none. The rest is geometry (four 0.25 m hurt spheres) | ~~12 of 24f~~ → per direction: duck 6 of 18f, sway 12 of 26f, back-sway 20 of 36f (lengths GH-measured; invuln still our pick) |
| Dodge chaining | successful dodge re-arms instantly; attacks buffer during step and fire at its end | measured (PCSX2): back-sway re-chains at 30f (lands at 26), side sway at 26f, duck at ~9f; 9 back-sways in a row with no cap ([details](god_hand_reference.md#dodges-measured-in-pcsx2)). Code: the windows are motion-data cancel bits; the dodge fires on the stick leaving an ~8% deadzone and is **not buffered** (attacks: 6f) | ~~no chaining~~ → **done:** ~~chain from frame 16, max 2~~ → GH timings: duck from 10, sway 26, back-sway 30, no cap; LIGHT/HEAVY mid-dodge queues for frame 10 / 18 / 30 |
| Combo scaling | from **5th hit**, −3%/hit, floor 50% | — | ~~0.92^n from 2nd hit, floor 35%~~ → **done:** BT3 curve |
| Anti-loop | same light stagger twice in one combo → push-out reaction | consecutive-hit counter caps at 4 | ~~none~~ → **done:** ~~repeated melee move~~ same special reaction (MoveData.loop_group) or 5th juggle hit per segment = push-out knockdown (a teleport starts a new segment) |
| Charged smash | full in 45f; tiers <0.3 / <0.99 / full; release on first full frame = invuln lunge | hold at charge marker, ~80f pool | 45f punch / 60f kick; smashes knock down from 0.3, held body blow ≥0.5 stuns, ~~full breaks guard~~ → **stage 1:** no guard crash (ki guard 40 → 56 ki at full, ~half a bar as measured), 4 light hits of armor while under way, momentum charges up to 1.4× faster right after landed hits |
| Rush string / finishers | 5 rush steps per half, blast mid-string = finisher by position (released = chargeable), up / down + blast = two more | player-built strings | **done 2026-11-23:** X x5 (ender), Y finisher by position, fwd / back + Y = upper hook / sweep, held Y charges (waits before the hit) |
| What knocks down | reaction per attack record; rush staggers never | launches by hit type, consecutive-hit cap 4 | ~~every HEAVY~~ → launchers, sweeps, smashes / finishers charged ≥30%, the full-string finisher, throws; others stagger |
| Guard | chip **cannot KO**; per-move guard results (push, ki-guard, attacker recoil); throws beat guard | no guard | ~~chip can KO; guard meter 100 → 50f break~~ → **done:** BT3 guard: 3 stick poses, per-move result per pose, ki guard → guard crash (75f, mashable), chip can't KO, counter guard |
| Throws | through guard; break = guard press within 10f | grab: ±45° facing, 3 m, blocked by invuln | ~~none~~ → **done:** THROW (RB), clean GUARD press within 10f (before or after the grab) breaks it from the front; back throw with stick back |
| Knockdown → get-up | auto at 180f; **any button = get-up any time**; direction = roll L/R/F/B; can guard on wake | tech in a motion window → quick recovery with 10f invuln; wake-up attack if button pressed late | ~~fixed 24f lie~~ → **done:** air tech (flick in the air from 18f = backflip onto the feet), quick rise on any button / up flick from 8f lying, LIGHT = get-up strike (spinning low sweep hitting all around, invulnerable through the spin), sway/backflip roll on a flick, auto get-up at 40f |
| Stun | 30/60/90f, each press −6f | dizzy 300f, each press −10f | guard crash 75f / charge stagger 36–60f, each press −6f |
| Attack tracking | turn max(1.8°, 30% of diff) per frame @30 | enemies 5.6°/f during windup, **locked at commit**, then a 10f fast slide | ~~12°/f through startup~~ → **done:** 6°/f, locks 2f before active |
| Ki on being hit | none (attacker gains per-move kiGain) | tension + dmg/maxHP×10 (max 10) | ~~+3 per hit taken~~ → **stage 1:** none |
| Ki charge | constant rate; slowest possible = full gauge in 16.7 s | — | 1 bar per 72f, full in 6 s; 10f wind-up before ki fills (specials work in it), 12f release lag (dodge / guard only), so a tap gains nothing |
| Forward dash | per-character speed, turn-arounds add speed | — | 6f ramp-up startup (dodge only), 7f at 16 m/s (dash attack window), 10f braking end lag (dodge only), 10f cooldown; ~4 m |
| Trades | higher-priority move wins; tie = both cancel + shake (measured: a smash under way takes a jab and still lands) | — | both hit, except a charge strike under way absorbs light hits (armor) |
| Rush vs rush | attacker mid-rush auto-guards incoming rush hits | — | trade |
| Low-HP guts | — | hit leaves 1 HP if HP was ≥11 | — |
| Perfect dodge | — (Z-counter is the timing defence) | none in code; a near-miss **duck** (enemy attack within 1.5 m) counts as a combo hit; an attack in the duck window = duck counter | first 4f of any dodge: ki 15, 30f counter window ×1.5, 6f freeze; perfect duck staggers 40f |
| Crowd attacks | — | no tokens: distance rank sets approach distance (1.8 / 5 / 8 / 12 m), flankers walk to the front, enemies behind hold off (cone ±60°…±180° by level), lunges only inside a facing cone, 10 s lunge cooldown, no attacks while the player is grabbed, a ducking player draws a likely-low attack ~56% (vs 1 in 8) | co-op tokens: 2 melee / 1 ranged per player, grab lock, optional facing-cone off-screen rule |
| CPU reaction | (b + b·rand), b = 22→0 by level, i.e. **44–88f** at lowest | per-level recovery 120/90/60/30f + rand(90) | 30 → 5f |

## Recommendations, highest payoff first

Each is a tuning-driven change (new knobs go in `FighterTuning`), testable
headless. Ordered by how much they should change *feel*.

1. *(Implemented.)* **Slow attack tracking, lock at commit.** Our startup tracking turns at
   12°/frame, roughly 2× God Hand's enemies. A sway started before an attack
   commits gets re-acquired instantly, which undercuts the God Hand dodge.
   Add `attack_track_turn_deg` (~6°/frame) separate from walk turn speed,
   optionally let moves end tracking a few frames *before* active
   (`track_frames` already exists per move).

2. *(Implemented.)* **Z-counter as a press window with mash lockout.** Replace the
   "guard held 1..6f" rule with: guard *press* opens a ~8f window; pressing
   again inside the cooldown (~58f) resets it (so mashing B fails, like BT3).
   Only the **first hit** of a move can be vanished. Cost 1 bar instead of 2
   (BT3: 20000/100000). Optional: window shrinks at low HP (8/6/4f).
   This keeps the approved "B just before a melee hit = vanish" control.

3. *(Implemented.)* **Gentler, later combo scaling + anti-loop.** BT3 leaves the first 4 hits
   unscaled, then −3%/hit to a 50% floor. Ours cuts the second hit already.
   Expose `scaling_start_hit`, `scaling_step`, `scaling_floor`. Pair it with
   a juggle limit: repeat of the same move (or the Nth airborne relaunch) in
   one combo → push-out / forced knockdown instead of a relaunch. Today the
   only loop limit is the 35% damage floor.

4. *(Implemented, plus a God Hand style air tech.)* **Get-up options.** Let a knocked-down fighter rise early with any button
   and roll with a stick direction (reuse sway/backflip motion), keeping wake-up
   invuln; stay down on no input up to a max (BT3: 180f — ours could be ~60f).
   Gives the defender a mix-up instead of a fixed timing the attacker can
   meaty.

5. *(Implemented; chain timing still to be checked against PCSX2.)* **Dodge chaining.** Allow cancelling a dodge into another dodge after the
   invuln frames (or immediately after a perfect dodge), and buffer an attack
   pressed during a dodge to fire on the first vulnerable frame. Measure God
   Hand's real chain timing first (see PCSX2 list).

6. *(Implemented on RB.)* **Throws.** Close-range grab that beats guard;
   break by pressing guard within ~10f. Without it, holding guard + meter is
   the safest play.

7. **Hitstop review.** BT3 uses none on normal melee, God Hand uses some.
   Measure God Hand before changing ours; possibly drop lights to 2–3f and
   lean more on per-hit camera shake for rush strings.

8. **Small ones.** *(Done: chip damage can't KO; mashing shortens guard
   crash / stagger stun by 6f per press.)* Rush-vs-rush trades resolve by
   priority instead of both hitting. No ki for the *defender* on hit (BT3) —
   or keep it as the God-Hand-style "tension" comeback, but scale it by damage
   (dmg/maxHP×10) instead of a flat +3.

Not recommending: BT3's Max Power mode / God Hand mode (tension is merged
into ki by design), BT3 dash clashes, God Hand's level meter (single-player
dynamic difficulty).

## What still needs PCSX2

How to record or pick footage for these: [footage_capture.md](footage_capture.md).

These live in unmatched code or disc data. Record at 60 fps (or use frame
advance) and count frames; note which 60 fps patch, if any, is active.

God Hand (Gene vs. a basic enemy, Level 1). *Dodge invulnerability and
input handling are now read in code (third pass), not measured.* Rearmed's
test mode (scripted pad + per-frame CSV, under Wine) could replace PCSX2
for the rest:

- Hitstop length: the two runtime words at `0x3BF190` / `0x3BF194`
  (RAM read during a fight).
- Per-move cancel windows and startup (motion data): earliest attack out
  of a sway / back-flip, a jab's startup.
- Camera shake on light/heavy hits; distance/height of the default camera.

BT3 (Goku Early vs. Goku Early, ground only):

- Rush string: frames per hit, cancel point, full 5-hit damage.
- Charge: time from empty to 1 bar and to 5 bars.
- Ki gained per rush hit / per smash.
- Smash charge to full, and stun duration.
- Throw startup and throw-break window.
