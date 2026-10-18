# Reference mechanics: God Hand & Budokai Tenkaichi 3 vs. us

Research notes from reading the two community decompilations (2026-10-18):

- **BT3** — https://github.com/z3xox/Tenkaichi3Decomp (working PC port; game
  logic largely matched, with system docs under `docs/systems/`).
- **God Hand** — https://github.com/LucasPicoli/god-hand-decomp (~47% code
  matched; the player dodge/cancel dispatcher is still unmatched asm).

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
| Hitstop on normal melee | **none** — camera shake per hit sells impact | global freeze, length unknown (unmatched) | 4 light / 8 heavy, global |
| Z-counter / guard vanish | guard **press** opens 8f window (6f <70% HP, 4f <30%); re-press during it = ~58f lockout (anti-mash); **first hit of an attack only**; 1 bar; no ki → free sidestep | — | ~~guard held 1..6f, any melee hit, 2 bars~~ → **done:** press window 8/6/4f by HP, 60f mash lockout, string openers only, 1 bar |
| After a paid vanish | forced counter-attack; opponent can Z-counter it back (unlimited duel) | — | ping-pong duel with shrinking window; ends with positions only |
| Escape from mid-combo | not possible (mid-string hits undodgeable) — anti-loop rule instead | mash-out of grabs | vanish escape from hitstun, 2 bars (approved design) |
| Dodge invuln | vanishing step: invuln for the whole ~14f burst; dash steps: first 20% | invuln is a countdown timer refreshed each state tick + tail (10/30/60f) | 12 of 24f |
| Dodge chaining | successful dodge re-arms instantly; attacks buffer during step and fire at its end | (unmatched) — chained back-sways are a GH staple | ~~no chaining~~ → **done:** chain from frame 16, max 2 in a row; LIGHT/HEAVY mid-dodge queues for frame 13 |
| Combo scaling | from **5th hit**, −3%/hit, floor 50% | — | ~~0.92^n from 2nd hit, floor 35%~~ → **done:** BT3 curve |
| Anti-loop | same light stagger twice in one combo → push-out reaction | consecutive-hit counter caps at 4 | ~~none~~ → **done:** repeated melee move or 3rd relaunch per segment = push-out knockdown (a teleport starts a new segment) |
| Charged smash | full in 45f; tiers <0.3 / <0.99 / full; release on first full frame = invuln lunge | hold at charge marker, ~80f pool | 45f punch / 60f kick; ≥0.5 stun, full breaks guard |
| Guard | chip **cannot KO**; per-move guard results (push, ki-guard, attacker recoil); throws beat guard | no guard | chip can KO; guard meter 100 → 50f break |
| Throws | through guard; break = guard press within 10f | grab: ±45° facing, 3 m, blocked by invuln | none |
| Knockdown → get-up | auto at 180f; **any button = get-up any time**; direction = roll L/R/F/B; can guard on wake | tech in a motion window → quick recovery with 10f invuln; wake-up attack if button pressed late | ~~fixed 24f lie~~ → **done:** air tech (flick in the air from 18f = backflip onto the feet), quick rise on any button / up flick from 8f lying, sway/backflip roll on a flick, auto get-up at 40f |
| Stun | 30/60/90f, each press −6f | dizzy 300f, each press −10f | guard break 50f / charge stagger 36–60f, no mash |
| Attack tracking | turn max(1.8°, 30% of diff) per frame @30 | enemies 5.6°/f during windup, **locked at commit**, then a 10f fast slide | ~~12°/f through startup~~ → **done:** 6°/f, locks 2f before active |
| Ki on being hit | none (attacker gains per-move kiGain) | tension + dmg/maxHP×10 (max 10) | +3 per hit taken |
| Ki charge | constant rate; slowest possible = full gauge in 16.7 s | — | 1 bar per 72f, full in 6 s |
| Trades | higher-priority move wins; tie = both cancel + shake | — | both hit |
| Rush vs rush | attacker mid-rush auto-guards incoming rush hits | — | trade |
| Low-HP guts | — | hit leaves 1 HP if HP was ≥11 | — |
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

6. **Throws.** Close-range grab that beats guard; break by pressing guard
   within ~10f. Without it, holding guard + meter is the safest play.
   Needs an input decision (BT3 uses dash double-tap when close).

7. **Hitstop review.** BT3 uses none on normal melee, God Hand uses some.
   Measure God Hand before changing ours; possibly drop lights to 2–3f and
   lean more on per-hit camera shake for rush strings.

8. **Small ones.** Chip damage can't KO (BT3). Mash to shorten guard-break /
   stagger stun (BT3: each press −6f). Rush-vs-rush trades resolve by
   priority instead of both hitting. No ki for the *defender* on hit (BT3) —
   or keep it as the God-Hand-style "tension" comeback, but scale it by damage
   (dmg/maxHP×10) instead of a flat +3.

Not recommending: BT3's Max Power mode / God Hand mode (tension is merged
into ki by design), BT3 dash clashes, God Hand's level meter (single-player
dynamic difficulty).

## What still needs PCSX2

These live in unmatched code or disc data. Record at 60 fps (or use frame
advance) and count frames; note which 60 fps patch, if any, is active.

God Hand (Gene vs. a basic enemy, Level 1):

- Back-sway, side-sway L/R, duck: frames from input to movement, to
  invulnerability end (test by dodging a jab at increasing delays), total
  length, and earliest chain into the next sway.
- Earliest attack out of a dodge.
- Hitstop on a jab vs. a heavy (freeze frames).
- Camera shake on light/heavy hits; distance/height of the default camera.

BT3 (Goku Early vs. Goku Early, ground only):

- Rush string: frames per hit, cancel point, full 5-hit damage.
- Charge: time from empty to 1 bar and to 5 bars.
- Ki gained per rush hit / per smash.
- Smash charge to full, and stun duration.
- Throw startup and throw-break window.
