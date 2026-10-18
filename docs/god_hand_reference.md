# God Hand: mechanics reference

How God Hand (PS2, Clover Studio / Capcom, 2006) plays under the hood,
extracted from the community matching decompilation
https://github.com/LucasPicoli/god-hand-decomp (read 2026-10-18, ~47% of
code matched). Use this to steer the God Hand half of the game. The
Tenkaichi half is in [bt3_reference.md](bt3_reference.md); the side-by-side
comparison and what we already changed is in
[reference_mechanics.md](reference_mechanics.md).

Mechanics and numbers only, in our own words. Never copy code from the
decomp (the game code belongs to Capcom).

## Biggest caveat

**The dodge code isn't matched yet.** The per-frame input/cancel dispatcher
(attack chaining, dodge cancels), the hit-volume update, the main player
move routine and what look like the sway states are still unmatched asm,
and the clone has no asm or ELF to read constants from. So the sway / duck /
back-sway frame data, God Hand's hitstop length, God Hand mode's
multipliers, the tension drain rate and the level thresholds are **unknown
from this source** — they need PCSX2 measurement (capture list in
[reference_mechanics.md](reference_mechanics.md#what-still-needs-pcsx2)).

Also, **strike timing lives in motion data**, not code: animation files
raise event flags for cancel/tech windows, the charge point, the impact
moment (which slows enemies) and the lunge marker. Startup/active/cancel
frames per move come from data that isn't in the repo.

## Units and conversions

- **Game logic runs at 30 Hz** (fairly confident: save data counts play
  time "in frames at 30 fps"). A global frame-step scale multiplies every
  speed — the hook PCSX2's 60 fps patches use. Frame counts below are
  converted to **our 60 Hz** (×2) unless marked `@30`; per-frame speeds are
  converted to m/s (×30).
- **Units ≈ 1 m** (camera looks at 1.06 above the feet, a held object sits at
  1.6, grab range 3.0, melee "stop" radius ~1.1).
- State model: four bytes (mode / phase / step / step-arg); a state's step 0
  starts a motion, step 1 runs it to the end and returns to idle.

## Invulnerability ("muteki")

- **A float countdown timer on the character**, not a hurtbox toggle.
  Attacks and grabs simply skip a target whose timer is above zero.
- **States re-write the timer every frame they run**, so you are invulnerable
  for the whole state *plus* a tail after it ends. Values seen: 10f (hit and
  grab reactions, beatdowns), 30f (knockdown, get-up, God Hand on/off), 60f
  (roulette moves, taunt "sorry"), 4–6f for small cases. Normal strikes
  don't set it.
- No "perfect dodge" slow-mo or counter window appears in matched code (it
  may live in the unmatched dodge states).

## Knockdown, tech and get-up

- **Knockdown:** the player turns to face the attacker; pending damage lands
  on touchdown; invulnerable throughout (30f refreshed).
- **Tech:** inside the motion's tech window, a stick input (likely the right
  stick) or any face button switches to a quick-recovery state with a short
  invuln tail — that recovery state is probably the dodge/sway family.
- Otherwise the player lies down, then gets up (30f invuln, refreshed). A
  button pressed in the last ~20 frames turns it into a **wake-up attack**.
- **Flinches:** one of three random flinch motions; "can act" from when the
  invuln timer runs out; another flinch type has 20f invuln.

## Guard, grabs and enemy tracking

- **No player guard state** exists — defence is dodging.
- **Enemy grab** fails if the player is invulnerable, holding an object,
  more than **45° off** the enemy's facing, or more than 0.5 m higher/lower;
  succeeds within **3 m**.
- **Enemy charge-grab telegraph** — the pattern that makes dodges fair:
  1. Wind-up: the enemy **keeps turning toward the player** at ~5.6°/frame
     (11.25°/frame @30).
  2. Commit: it picks a point just behind the player, faces it instantly,
     and **slides there in ~10 frames with no more tracking**.
  3. Grab test at the end.
  Track during wind-up, lock at commit, short fast active phase.
- Other enemy turn rates: the same 5.6°/frame for 44 frames after a 30-frame
  delay; double that when re-facing during hit reactions.
- **Held by an enemy:** the enemy deals damage every 20 frames; mashing
  speeds up your escape animation from ×1 to ×3. Drain-holds also eat
  tension every frame and lower the level meter.

## Tension and God Hand mode

- **Gauge size:** 120 + 30 per tension item (120–270). Display tiers below
  50% / up to 75% / above. "God Hand ready" = one full bar (120).
- **Gains:**
  - Landing a hit: **+1.5 on the first hit of a combo, +0.5 on later hits**
    (halved at the top level). The combo window is 90 frames.
  - **Taunting** an enemy into anger: +12.
  - Throws/holds on enemies: +0.5 to +1 per hit.
  - **Taking damage:** + damage ÷ max HP × 10, capped at 10.
  - ×1.25 on Easy. **No gain while God Hand mode is active.**
- **Tension-boost orb move:** 1 orb = +30, 2 orbs = +80; slows enemies to
  10% speed and gives 60f invuln.
- **God Hand activation:** invulnerable throughout; at the motion event the
  mode turns on and the gauge's *floor* is set to current − 120 — **one
  activation costs exactly one bar**, the rest is protected. Turning it off
  has its own short invulnerable motion.
- **While active** the gauge drains per frame (rate unknown), paused during
  roulette moves, ×0.25 during beatdown prompts; reaching the floor ends the
  mode. The damage/speed boost itself is unmatched (attack power is the
  likely carrier).

## Roulette moves

- Orbs are the God Reel slots. An orb seems to be spent **only when the move
  first connects** — a whiff may be free (moderate confidence).
- About 19 roulette states share a template: 60f invuln (refreshed), enemies
  can't act, tension drain paused, the arm wrap comes off and goes back on,
  a motion camera.
- **Enemies run at 10% speed for the whole move** (dropping to 3–20% at the
  impact marker) while the player runs at full speed. The slow-mo is a
  global enemy speed multiplier re-applied every frame.
- Flat damage examples: 80–230, 400, 700. Ordinary strikes deal
  attack power × 10 / 15 / 20.

## Strikes, combos and reactions

- **Strike template:** homing turn ~5.6°/frame for up to 100 frames
  (heavies: ~11°/frame for 20 frames); lunge proportional to the remaining
  distance (more if the stick is held), decaying each frame; forward motion
  stops within ~1.1 m (1.4 for some moves) of the target. The player's HP
  can't drop below 1 during their own attacks.
- **Hold-to-charge:** at the charge marker, holding slows the animation to
  2.5% speed while a charge pool drains (≈80 frames max); past a threshold
  the hit gets a damage bonus and effect.
- **Hitstop** is a global freeze (everything skips its tick); its length is
  set in unmatched code.
- **Enemy launches** (vertical speed by hit type, m/s): 3.9, 1.17, 7.0, 5.46
  (3.9 on some), 2.73, 0.59, 1.95 — ×1.1 for heavy enemy types, ×0.7 for
  some others. **Gravity is asymmetric: ~11.7 m/s² rising, ~7.0 m/s²
  falling** — launches float on the way down. Two hit types trigger the
  big-hit effect. A consecutive-hit counter caps at 4.
- **Enemy stun after landing from a knockdown,** by level meter: 0 / 1/8 /
  1/4 / 1/4 / 1/2. Stunned enemies get 20f invuln.
- **Enemy recovery before acting:** 120 / 90 / 60 / 30 frames + random 0–90
  (by level); a 1/3 chance of a fast 40-frame recovery flagged to counter;
  then each frame a small chance to counter-attack if the player is close.
- **Beatdowns** on a dizzy enemy: QTE-style mash loops of at least 180
  frames where mash rate sets the animation speed (×0.7 … ×2.0) — faster
  mashing = more hits.
- **The mash meter** (beatdowns, grab escapes, death crawl): measure the gap
  between face-button presses; a gap under the tier's limit goes up a tier,
  over it goes down. Limits shrink from 18 to 4 frames by tier. No press for
  20 frames drops a tier every 10 frames. Tier = animation speed.
- **Player dizzy:** a 300-frame timer, −10 per face-button press (plus a
  larger amount for another input, unidentified).
- **Damage taken:** × level factor 0.6 / 0.8 / 1.0 / 1.0 / 1.2, ×0.5 on Easy
  else ×0.75, further reduced by an unidentified counter. **Guts rule:** a
  hit that would kill leaves 1 HP if you had at least 11.

## Taunts and the level meter

- **Taunt:** one of two motions; at its event it angers enemies in a cone
  (radius 15 m, ±30°). Angering any: +12 tension and +250 level points.
- **"Sorry" move:** spends an orb, 60f invuln, pacifies enemies and **resets
  the level to 1** when it ends.
- **Level meter (dynamic difficulty)**, levels 1–5 (4 shows as "DIE"):
  - Points: +20 per strike landed, +50 per combo hit, +100 on a 5th hit,
    +100 per beatdown, +250 per taunt; −320 per hit or grab taken, −1000 for
    heavy hits / knockdowns.
  - Gains scale down as the level rises (×1.5 … ×0.5); losses don't.
  - "Grace": reaching a level grants a buffer that absorbs one drop.
  - Higher levels speed enemies up, raise their stun/counter odds and
    shorten their recovery (above).

## Camera

- Normal follow: target slightly to one side at chest height (−0.2, 1.06),
  ~4° pitch, distance 4 m, FOV 31 (unit/axis unconfirmed).
- A separate lock-on chase mode exists (unmatched).
- **Shake:** two sinusoidal channels, each decaying per frame; per-hit values
  are unmatched.
- Roulette and God Hand moves use authored motion cameras.

## Where we stand

| God Hand mechanic | Us |
|---|---|
| Right-stick sways / duck / back-sway | ✅ (frame data still unmeasured) |
| Invuln as state + tail | ✅ in effect (dodge invuln, wake-up tail) |
| Attacks track in startup, lock at commit | ✅ (6°/frame, lock 2f before active) |
| Tech out of knockdowns | ✅ air tech, quick rise, rolls |
| Dodge chaining / dodge → attack | ✅ |
| Hold-to-charge strikes | ✅ |
| Global hitstop freeze | ✅ (length vs God Hand unmeasured) |
| Tension gauge → God Hand mode | merged into ki by design; no mode |
| Tension (ki) from taking damage, scaled by damage | ✗ flat +3 |
| Taunts | ✗ |
| Roulette moves with opponent slow-mo | partial (ultimate freeze; no slow-mo) |
| Floaty asymmetric launch gravity | ✗ (one gravity, 24 m/s²) |
| Stun / dizzy + beatdown mash | partial (staggers, no mash) |
| Mash meter for escapes | ✗ |
| Guts (1 HP) rule | ✗ |
| Wake-up attack | ✗ (rise/roll only) |
| Level meter (dynamic difficulty) | ✗ (CPU levels are fixed) |

## Steering toward God Hand

Ideas that would make the game read more "God Hand", roughly by payoff.
None are scheduled; pick consciously, since some pull against Tenkaichi.

1. **Measure and match the dodges** in PCSX2 (sway/duck/back-sway invuln,
   total length, chain timing). This is the single biggest feel item and
   the decomp can't give it yet.
2. **Taunt** button: short, punishable animation that grants ki and maybe
   angers/buffs the CPU — God Hand's risk-for-reward loop.
3. **Floaty launches:** lower falling gravity than rising gravity for
   knocked-down fighters (GH ≈ 0.6 ratio), so juggles have hang time.
4. **Opponent slow-mo instead of freezes** for supers/ultimate: run the
   victim at 10% for the move's duration while the attacker stays at full
   speed (deterministic: a per-fighter speed scale in the sim).
5. **Ki from damage taken scaled by damage** (dmg ÷ max HP × 10 style), and a
   first-hit bonus on ki gained from hitting — rewards opening hits.
6. **Dizzy → beatdown:** charge-strike stuns could open a short mash window
   where the mash rate sets the follow-up speed/hits.
7. **Wake-up attack:** a button held near the end of lying down = a
   get-up strike (invulnerable startup) as a third wake-up option.
8. **Guts rule** (a killing hit leaves 1 HP once) for comeback drama.
9. **Level meter for the CPU:** an optional single-player mode where the CPU
   level rises while you play well and drops when you get hit.
