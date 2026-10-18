# Budokai Tenkaichi 3: mechanics reference

How DBZ Budokai Tenkaichi 3 (PS2, 2007) plays under the hood, extracted from
the community decompilation / PC port
https://github.com/z3xox/Tenkaichi3Decomp (read 2026-10-18; its own notes
live in `docs/systems/*.md`, code in `src/battle/`). Use this to steer the
Tenkaichi half of the game. The God Hand half is in
[god_hand_reference.md](god_hand_reference.md); the side-by-side comparison
and what we already changed is in
[reference_mechanics.md](reference_mechanics.md).

Mechanics and numbers only, in our own words. Never copy code from the
decomp (the game code belongs to its rights holders; the port code is AGPL).

**Confidence tags:** **[V]** read in matching C · **[I]** inferred ·
**[DATA]** lives in per-character / per-attack disc data that the decomp
doesn't contain (most per-character numbers: charge rate, speeds, damage,
cancel frames). The decomp gives the *formulas, fixed constants, windows and
resolution order*.

## Units and conversions

- **The sim runs at a fixed 30 Hz [V]**, integer frame counters, no delta
  time. Every frame count below is converted to **our 60 Hz** (×2) unless
  marked `@30`. Per-frame rates are halved accordingly.
- Speeds are authored in **km/h** (units/s = km/h ÷ 3.6). The size of a game
  unit is unknown; scale hints: grab range 100 units, "near" range is 2–5
  body heights clamped to 20..150. Normalise to body height when porting.
- **Gauges:** HP 10000 per bar (multiple bars per character, [DATA] count).
  Ki 0..100000 = **5 bars of 20000** — same shape as ours (our bar = 100, so
  divide BT3 ki by 200). Blast stocks are a separate gauge (up to 7 × 100000).
  Max Power gauge 0..30000.

## Ki

- **Charging [V]:** constant rate per character, no acceleration. The floor
  is fast enough that even the slowest character fills the whole gauge in
  ≤16.7 s (≤3.3 s per bar). Animation: start → loop (ki only added in the
  loop) → burst. Releasing before the burst returns to neutral. Water has
  its own rate. *(Ours: 1.2 s per bar, 6 s full.)*
- **Passive regen [V/I]:** per-character rate, only while ki is below a
  per-character limit (abilities raise it). Gated to certain idle/charge
  animations — exact gating uncertain. Benched tag partners regen HP/ki.
- **Ki from hits:** the *attacker* gains each attack's kiGain [DATA]. The
  **defender gains nothing** from being hit or guarding.
- **Fixed costs [V]** (in our bars):

  | Action | Cost |
  |---|---|
  | Teleport counter (paid Z-counter) | 1 bar |
  | Vanish behind the opponent (guard tap when close) | 1 bar |
  | Vanishing side-step | needs ≥0.5 bar, *costs nothing* (the charge is dead code) |
  | Homing / free dash | needs 0.05 bar, then drains per frame [DATA] |
  | Circle dash to the back | needs 0.5 bar |
  | Chase dash after a hit | needs 0.25 bar |
  | Armour absorbing a hit | 0.1 bar (defender) |
  | Guarded rush-type super | 1 bar from the *defender* |
  | Ki blasts, Blast 2, Ultimates | [DATA] |

- **Max Power mode [V]:** charge with a full ki gauge and at least one blast
  stock → a 30000 gauge fills over a per-character time; when full, one stock
  is spent, a burst shockwave hits nearby, the camera shakes. While active
  the gauge drains (pauses while still charging); empty = mode ends. Unlocks
  the Ultimate and Max-Power rush finishers, +20% Blast 2 damage, raises
  chase limits.
- **Ki exhausted = guard crash [V]:** a ki-costing guard that empties your
  ki puts you in an exhausted state: no guard, no dodges, slow recovery that
  speeds up ×4 on each face-button press (mash out) until a target ki.
- **Blast stocks:** gained during certain animations (≥ a floor rate), +0.5
  stock to a defender on a "push-off" guard, +0.05 for deflecting a blast,
  +1 from some abilities on a perfect dodge.

## Z-counter: the defence windows

The heart of BT3 defence [V] (`btl_char_move.c` UpdateDefenseTimers). Each
fighter has a set of countdown windows. **A guard press while locked on
opens them**; each counts down per frame and is live while above zero.

- **Anti-mash:** pressing guard again before a window has fully reset puts it
  back into a ~58-frame lockout. Mashing guard kills your counter; you must
  wait about a second without pressing to re-arm.
- **A successful dodge re-arms instantly**, so dodges chain.
- While a hit reaction is pending the melee window closes (but re-arms).

| Window | Opened by | Length (60 Hz) | Purpose |
|---|---|---|---|
| Melee dodge | guard press | **8f at HP ≥70%, 6f below, 4f below 30%** | Z-counter vs melee |
| Blast / super dodge | guard press | 4f (8f right after being thrown) | sidestep projectiles, rush supers |
| Counter | Up + Rush | **2f** | counter-hit out of a guard-like pose |
| Blast deflect | guard + side (character flag) | 10f, 30f lockout | deflect a ki blast |
| Throw break | guard press | 10f | break a throw |
| Rush-super break | guard press | 4f (8f after a throw) | escape a rush super |

**Resolution [V]** (`btl_char_hit.c` CheckDodge):

- Defender must be "free" (alive, not exhausted, not stunned) and in an
  animation that allows it [DATA]. Attack must be flagged dodgeable and it
  must be **the first hit of that attack** — mid-string hits can't be
  Z-countered. Some attacks shorten the window by 1 frame @30.
- With ≥1 bar and an attack flagged for it: pay 1 bar → **teleport counter**,
  forced into one of three "evasion attacks" (chosen by a shared counter and
  relative height), vanishing/warping behind first.
- Otherwise: a **free sway sidestep** (left / right / back by held
  direction; with no direction the pick is deterministic from a counter).
- Skills can grant timing-free auto-evasions (up to 3 stacks).
- **No cap on duels:** each counter attack is a normal first hit, so the
  other side can Z-counter it back, 1 bar each time, until someone mistimes,
  mashes into lockout, or runs out of ki.

**Vanishing step** (the sidestep itself) [V]: a 14-frame burst in the chosen
direction (speed zero in the last 4), **invulnerable throughout**, adds the
opponent's velocity while locked on (keeps relative position). A successful
one adds 2 s to the round timer. **Attacks pressed during the step are
buffered and fire as it ends** → dodge-into-counterattack.

**Manual teleports:** guard + direction tap (≥0.5 bar, locked on) = the
vanishing step (free in practice). Guard tap when close (≥1 bar, with a
≥30-frame gap since the last guard press for some characters) = **vanish
behind**: 14 frames invulnerable, warp behind with a 180° turn, 1 bar.

**Rush parry** (some characters): guard held + blast enters a ki-draining
stance; in its first 20 frames a frontal rush hit is parried — the attacker
is forced into a triple-speed auto rush and pays 0.1 bar.

## Melee

- **Inputs [V]:** rush tap; rush held 12f + direction = charged smash; blast
  tap = release under 14f, blast held exactly 12f = charged ki blast; double
  tap = second press within 14f; grab = dash double-tap when close.
- **Rush chain:** 10 animations in two strings of 5; steps 4 and 9 are the
  enders. The step counter persists through vanish steps and resets when you
  leave the rush family. Next rush cancels at an animation cancel point
  [DATA]. **Branches mid-string:**
  - blast mid-string → a character-specific **rush finisher** (chosen by
    position in the string, chargeable);
  - rush held + direction → **charged smash** in 5 directions (up, down,
    left, right, neutral — neutral differs between the two halves);
  - up+blast / down+blast → two more finishers.
  - A landed ender auto-queues a follow-up (by height) past 40% of its
    animation; dash at 50% chases.
- **Rush vs rush:** a fighter who is mid-rush **auto-guards incoming rush
  hits** — trading rushes becomes a mutual block with chip, not a trade.
- **Charged smash [V]:** full charge in 45 frames at base rate. The rate
  speeds up with *momentum* (which grows on each hit landed, +big when the
  defender ki-guards, decays over time) — landing hits makes smashes charge
  faster. Tiers: weak <30%, medium <99%, full. Release animation plays at
  speed 1 + level. **Just-release:** releasing on the first frame at full
  gives an invulnerable lunge. Max-Power skill: holding at full while close =
  cinematic full smash that freezes the opponent.
- **After a smash:** blown-away victim → chain at 70% of the animation;
  knocked-back → dash/main follow-up at 70%; else rush follow-up at 60%.
- **Chase limits per combo:** 1 homing-dash chase and 1 **vanish chase**
  (blast + direction: vanish, warp ahead of the victim, strike). More in Max
  Power / with abilities.
- **Damage scaling [V]:** first 4 hits full, then −3% per hit, floor 50%
  (ability: −2%, floor 70%). +20% from behind. ×0.5 into some defensive
  animations. Then the defence stat curve. Damage ≥10 rounds *up* to a
  multiple of 10.
- **Anti-loop [V]:** each reaction type has a per-combo counter; **taking the
  same light stagger a second time in one combo becomes a push-back** instead
  — strings must vary or end in a launcher/smash.
- **Trades [V]:** simultaneous hits → higher priority wins; a tie cancels
  both with a camera shake.
- Hits only connect within ±90° of the attacker's facing unless flagged.

## Guard

- Hold guard; **3 poses** — mid (neutral), up, down; switching takes 6f of
  the new input. **Guard fails from behind.**
- Every attack defines a **guard result per pose** [DATA]:

  | Result | Effect |
  |---|---|
  | Plain | pushback |
  | Ki guard | defender pays ki, half push, attacker gains momentum; ki at 0 → **guard crash** (exhausted) |
  | Push-off | attacker recoils, defender +0.5 blast stock, half push |
  | Unblockable | in that pose (breaks guard by height) |
  | Push-stop | push-off plus a few frames of freeze on both |

- **Chip can't KO** (leaves 1 HP).
- Get-up and guard-recoil animations can guard immediately (with the pose
  chosen by the held direction).
- **Counter guard:** the 2-frame Up+Rush window on a first hit → no chip,
  brief freeze, forced counter attack.
- **Throws go through guard** (only the grab range/facing test applies);
  break with a guard press in the 10f window while facing.

## Movement

- Walk, dash, homing dash and step speeds are per-character [DATA], capped.
- **Dash:** each turn-around while dashing adds speed (up to ×1.5).
- **Homing dash** (dash + charge, locked on, tiny ki): steers at the
  opponent, drains ki, stops when blocked, after ~32 slow frames or on
  losing lock. Free dash = same with a direction.
- **Circle dash** to the opponent's back (0.5 bar).
- **Steps** (dash + direction, close, locked on): back/left/right relative to
  the opponent line; move between 10%–60% of the animation; **invulnerable
  for the first 20%**. Step-in = short forward dash that accepts attacks.
- **Turning:** proportional (30% of the remaining angle per frame @30, min
  1.8°, max 36°). More than ~97° off the opponent = turn first before you
  can attack or guard.
- Gravity ramps per frame to a terminal speed; knockback impulses decay by
  a fixed amount; a new impulse only replaces a longer-lasting one.
- Movement is camera-relative; in lock-on the camera yaw chases the
  opponent at 25% per frame @30.

## Knockdown and recovery

- **Staggers:** in place, animation variants cycle (not random). Leaving
  one starts a 30-frame "recently hit" timer.
- **Heavy stagger / ground bounce:** the victim's **mash rate** speeds up the
  animation.
- **Launch:** vertical speed scales with attack strength; **air recovery
  input from 18f**; a wall = wall crash.
- **Knock-back:** duration scales with strength; holding a direction at the
  end recovers.
- **Blow-away:** 100 / 30 / 64 frames by type; air recovery from 18f (costs
  ki); some characters mash out. **A floor crash costs HP** (500 of a
  10000 bar). Walls and the opponent produce crash reactions.
- **Stun:** 30/60/90 frames; each face-button press removes 6.
- **Lying down:** automatic get-up after **180 frames**; any time earlier
  while free: face button = neutral get-up, **direction = roll** left / right
  / forward / back (mirrored by facing vs camera). Get-ups can guard and the
  Z-counter windows work as soon as you're free.

## Hit feel

- **Ordinary melee hits have no hitstop at all [V].** Freezes exist only for
  push-stop guards / counter guards (4–6f), dash clashes, and cinematic
  super start-ups (which freeze the *other* fighter).
- Impact is sold by **camera shake** (per attack record [DATA]; pads vibrate
  at half), plus animation events: heavy impact = strong shake for ~0.2 s +
  flash, light = half that for ~0.1 s.
- Each hit adds a little time back to the round timer.

## Health and damage formulas

- Melee damage = record × attack stat curve (×0.5 at −20, ×1 at 0, ×3 at
  +80), ±10% from abilities, divided across multi-hit animation events.
- Rush supers: per-hit = total / (hits + 5), capped.
- Clash losers take damage from the winner's mash count.
- Low-HP flash at ≤1 bar.

## Clashes

- **Dash vs dash (same type):** a 152-frame mash-off, higher count wins (an
  automatic count every 8 frames if you don't mash).
- **Dash vs a different dash type:** a vanish-chase of exchanges with a
  button prompt; windows 36 / 30 / 24 frames by level; a winner after 7+
  uneven exchanges.

## CPU AI

- Difficulty 0..29 internally (menu levels map to 0/6/13/21/29); every knob
  is a lerp between a level-0 and level-29 value.
- **Reaction delay:** base + base × random, base shrinking with level —
  **45–90 frames at the bottom, 0 at the top**. A second delay kind runs
  60 → 20 frames.
- Rules are re-evaluated every frame; "slowness" comes from probability
  rolls and timers, not a think interval.
- Plays through a virtual pad (same input path as a human), toggling press
  bits on alternate frames to repeat presses.
- Full-charge chance 10–50% by level. Answers button prompts instantly and
  perfectly (worth toning down in a copy).

## Unknown from the decomp

Per-character / per-attack data (charge rates, regen limits, speeds,
damage, push, launch angles, guard results, cancel frames, which animations
allow dodging/regen), the real-world size of a unit, and exactly which
attacks are Z-counterable or teleport-counterable (most likely rushes and
smashes). These need PCSX2 measurements (see
[reference_mechanics.md](reference_mechanics.md#what-still-needs-pcsx2)).

## Where we stand

| BT3 mechanic | Us |
|---|---|
| 5-bar ki gauge, hold to charge | ✅ (faster: 1.2 s/bar) |
| Z-counter: guard-press window, HP-tightened, anti-mash, first hit only, 1 bar | ✅ (guard vanish) |
| Vanish duel ping-pong | ✅ vanish battle (shrinking window, escalating cost) |
| Combo scaling 4 free hits, −3%, floor 50% | ✅ |
| Anti-loop push-back | ✅ (repeated move / relaunch cap → push-out) |
| Early get-up + directional rolls | ✅ (+ God Hand air tech) |
| Dodge re-arm / buffered counterattack | ✅ (dodge chaining, queued attacks) |
| Charged smashes | ✅ LIGHT charge = directional smash (forward launch, back ground bounce, sides knock away); no just-release, no momentum |
| Teleport chase after a hit | ✅ offensive teleport (2/combo); left stick places every teleport around the opponent |
| Vanish escape out of a combo | ours only (BT3 can't break mid-string) |
| No hitstop, camera shake instead | ✗ we use 4/8f hitstop |
| Throws through guard + throw break | ✅ THROW (RB); clean GUARD press within 10f breaks it from the front; stick back = back throw |
| Guard poses / per-move guard results | ✅ stick high/mid/low, 6f switch; plain / ki guard / push-off / push-stop / unblockable per pose |
| Ki-guard → guard crash / exhaustion | ✅ (guard meter removed; crash mashed out, ends with a 0.5-bar refill) |
| Chip can't KO | ✅ |
| Counter guard (Up + Rush, 2f) | ✅ guard + stick forward + LIGHT; forced counter launcher |
| Guard straight out of a get-up | ✅ |
| Rush vs rush auto-guard, priority trades | ✗ (both hit) |
| Max Power mode, blast stocks | ✗ |
| Homing / circle dash, step dodges | ✗ (forward dash only) |
| Defender gets no ki on hit | ✗ (+3 per hit taken) |
| Mash to shorten stun | ✅ (guard crash and staggers, −6f per press) |
| Dash clashes, beam struggles | ✗ (beam struggles excluded by design) |

## Steering toward BT3

Ideas that would make the game read more "Tenkaichi", roughly by payoff.
None are scheduled; pick consciously, since some pull against God Hand.

1. *(Implemented.)* **Throws** that beat guard, broken by a timed guard
   press (10f). Gives the guard/vanish game its missing third option.
2. **Rush branching:** mid-string finishers on a second button and a
   *(implemented)* directional charged-smash set (up = launch, down = ground bounce, sides =
   sideways knock-away), with BT3's chase follow-ups.
3. **Camera shake over hitstop** for rush strings: cut light hitstop to 0–2f
   and lean on shake; keep freezes for supers and big finishers.
4. **Ki economy:** slower charge, defender gets no ki from hits, attacker
   gains per-move ki. *(The ki-guard → guard crash part is implemented and
   replaced the guard meter.)*
5. **Homing dash / circle dash** costing small ki: BT3's mobility without
   flight.
6. **Max Power mode** (full ki + charge → temporary boost with a draining
   gauge) as the Tenkaichi-flavoured comeback/finisher state.
7. **Rush-vs-rush auto-guard** and priority trades, so mashing into each
   other's strings stops being a coin flip.
8. *(Implemented.)* **Guard poses** (high/mid/low guard via the stick) with
   per-move results (`MoveData.guard_results`, generated in
   `tools/generate_moves.gd`: matched heavy = push-off, neighbouring pose =
   ki guard, opposite extreme = unblockable; lights plain; smashes, supers
   and beams always ki guard).
