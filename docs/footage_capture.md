# Footage capture guide

How to record (or pick) God Hand and Budokai Tenkaichi 3 gameplay so it can
fill the gaps the decompilations leave (see
[reference_mechanics.md](reference_mechanics.md#what-still-needs-pcsx2)).
The footage gets split into frames and measured frame by frame; results go
into [god_hand_reference.md](god_hand_reference.md) /
[bt3_reference.md](bt3_reference.md) and then into our tuning.

## Record it yourself, or find a video?

| What we want to measure | Own PCSX2 recording | YouTube video |
|---|---|---|
| Total length of dodges, recoveries, get-ups, strings | ✅ | ✅ |
| Hitstop, camera shake / zoom, launch arcs, knockback distance | ✅ | ✅ |
| Combo rhythm (gaps between hits) | ✅ | ✅ |
| **Startup** (button press → action) | ✅ with input display | only with input display |
| **Invulnerability windows** (dodge vs attack timing) | ✅ (deliberate tests) | rarely — needs lucky footage |
| **Dodge chain timing** (earliest re-dodge) | ✅ (mash tests) | only if someone mashes on camera |
| Ki charge / gain rates (BT3 HUD) | ✅ | ✅ if the HUD is visible and uncut |

**Rule of thumb:** a YouTube video covers "how long / how it looks". The
God Hand dodge (startup, invuln, chaining) really wants your own recording
with an input display. A mix works well: find videos for the BT3 and
hit-feel items, record only the God Hand dodge tests.

## Recording setup (PCSX2)

1. **Region: NTSC (US/JP).** PAL runs at 50 Hz and changes every timing.
2. **No 60 fps / speed patches**, emulation speed 100% (frame limiter on).
   Widescreen patches and upscaling are fine.
3. **Input display (most important for startup and invuln):** turn on the
   on-screen input display if your PCSX2 build has one (Settings →
   On-Screen Display → *Show Inputs*). Otherwise any input-overlay tool that
   shows the pad on top of the capture works. Without one, only durations
   can be measured.
4. **Frame counter (optional, great):** PCSX2's *Input Recording* (Tools /
   System menu) shows a frame counter and saves the exact per-frame inputs
   to a `.p2m2` file. Recording a `.p2m2` *while* capturing video gives
   exact press timings — send both files.
5. **Capture:** either PCSX2's built-in video capture (exact emulated frames,
   no drops — preferred) or OBS. Settings:
   - **60 fps**, constant frame rate; ≥720p.
   - H.264/H.265 at high quality (CRF ≈ 15–18 or ≥15 Mbps); avoid
     motion blur / frame interpolation / "smooth" filters.
   - mp4 or mkv. Audio on (sounds help mark impacts).
6. **HUD visible**, no overlays covering the fighters.
7. **Camera:** keep it as still as possible; a side-on view of attacker and
   target makes distances measurable.

### Recording conventions

- **One scenario per clip**, named by its ID below (`G1_backsway.mp4`), or one
  long video plus a timestamp list.
- **~1 second of standing still** between repetitions, so each rep is easy to
  isolate.
- Keep clips short (under ~60 s). Menus, loading and cutscenes can be
  skipped.
- Add a `notes.txt` with one line per clip: what you did and anything you
  noticed ("rep 3: dodged late and got hit", "60 fps patch OFF").
- Put everything in one folder (e.g. `~/Videos/gh_capture/`) and send the
  path.

## Shot list: God Hand

Gene, early Stage 1 thugs, Level 1 (lowest level meter) unless noted.
Priority: ★★★ = only measurable this way, ★ = nice to have.

| ID | Pri | Setup / what to do | Reps | What gets measured |
|---|---|---|---|---|
| G1 | ★★★ | **Back-sway** in neutral, no enemy attacking | 5 | startup, total length, distance moved, earliest next input |
| G2 | ★★★ | **Side-sway left**, then **right** | 5 each | same, plus arc around the enemy |
| G3 | ★★★ | **Duck** | 5 | same, plus how long the body stays low |
| G4 | ★★★ | **Chain back-sways as fast as possible** (mash the stick) | 3 runs of ~5 | earliest chain frame, max chain, any lockout |
| G5 | ★★★ | Sway / duck, then **attack as early as possible** | 5 per dodge | earliest attack out of each dodge |
| G6 | ★★★ | **Invuln test:** let a thug throw a single punch, dodge **progressively later** each rep (from early to "got hit") | 10–15 | the invuln window: last frame a dodge still avoids the hit |
| G7 | ★★ | **Perfect / near-miss dodge** (if a slow-mo or flash triggers on very late dodges) | 5 | whether a perfect-dodge window exists, its length, any slow-mo |
| G8 | ★★ | **Hitstop:** default combo on a thug, then a single heavy kick | 3 each | freeze frames on light vs heavy hits, camera shake |
| G9 | ★★ | **Launcher / knock-up** on a thug, let it fall without follow-up | 3 | rise vs fall time (the asymmetric gravity), height |
| G10 | ★★ | **Gene knocked down:** (a) don't touch anything, (b) press dodge/tech at different moments while falling and on the floor, (c) hold a button to wake-up attack | 3 each | tech window, quick-recovery length, natural get-up time, wake-up attack |
| G11 | ★ | **Charge strike:** hold to full, release | 3 | charge time, damage bonus visible? |
| G12 | ★ | **Taunt**, **God Hand activation**, one **roulette move** | 1–2 each | lengths; roulette enemy slow-mo amount |
| G13 | ★ | Walk/run in a circle around a thug with the camera following; enter/leave lock-on if any | 1 | camera distance, height, lag, turn speed |

## Shot list: Budokai Tenkaichi 3

Training / Dueling mode, **Goku (Early) vs Goku (Early)**, flat ground,
no flight. Dummy standing still unless noted. If the dummy can't be set to
attack, use a second controller (a friend, or alternate quickly) or a CPU
battle at the lowest difficulty.

| ID | Pri | Setup / what to do | Reps | What gets measured |
|---|---|---|---|---|
| B1 | ★★★ | **Full rush string** (both 5-hit strings) on a standing dummy, then on a guarding dummy | 3 each | frames per hit, cancel point, total damage, chip |
| B2 | ★★★ | **Charge ki from empty to full** with the HUD visible, uninterrupted | 1–2 | time per bar, constant vs accelerating |
| B3 | ★★★ | **Ki gained per hit:** a rush string and a single smash, HUD visible, starting from a known ki amount | 3 | kiGain per rush hit / smash |
| B4 | ★★★ | **Z-counter / teleport counter:** dummy (or partner) attacks with rushes; tap guard just before impact; also once **mashing** guard | 5 + 3 mashed | counter-window feel, vanish duration, warp position, mash lockout |
| B5 | ★★ | **Charged smash** at each tier: tap-release, half, full, and full with an instant release (just-release) | 3 each | charge time per tier, release speed, knockback, stun |
| B6 | ★★ | **Steps & vanishing step:** dash+direction steps, guard+direction vanish steps | 5 each | length, distance, invuln (if a dummy attack passes through) |
| B7 | ★★ | **Throw** on a guarding dummy; **throw break** (partner throws you, you tap guard) | 3 each | throw startup/range, break window |
| B8 | ★★ | **Knocked down:** stay down (natural get-up), quick rise, rolls in each direction; **air recovery** after a launch | 2 each | auto get-up time, earliest rise, roll lengths, air-recovery timing |
| B9 | ★ | **Walk, dash, homing dash** across a measured stretch (pick two landmarks) | 2 each | speeds |
| B10 | ★ | **Hit feel:** light rush hit vs smash vs Blast 2; watch for any freeze | 3 each | confirm no hitstop; camera shake strength and length |
| B11 | ★ | **Max Power:** charge at full ki until it triggers, then idle until it ends | 1 | trigger time, duration, drain |

## Picking a YouTube video instead

Good candidates, best first:

1. **TAS / tool-assisted** videos (exact inputs) or **tutorials with an
   input display**.
2. **Mechanics breakdowns / frame-data videos** ("God Hand sway tutorial",
   "God Hand advanced dodging", "Budokai Tenkaichi 3 Z counter tutorial",
   "BT3 combo guide input display").
3. Clean **combo videos** with no edits mid-combo.
4. Plain gameplay as a last resort (needs precise timestamps from you).

Check before sending:

- **Native frame rate**: 60 fps uploads ("1080p60" in the quality menu)
  preferred; 30 fps is acceptable (both games run their logic at 30 Hz).
- **No cuts, slow-mo or speed-ups** during the actions (or say where they
  are).
- **No 60 fps game patch** (or note it — it changes the timings).
- HUD visible for any ki/damage measurement; NTSC version if you can tell.

Send **links with timestamps per scenario ID**, e.g.
`G4: https://youtu.be/xyz?t=83 (chained back-sways 1:23–1:31)`. Footage at
the exact moments matters far more than the length of the video.

## What happens next

Clips (or links) → frames extracted with ffmpeg → frame counts per scenario
→ numbers written into the per-game reference docs with a confidence note
→ tuning updates in `core/tuning/*.gd` + `data/tuning/*.tres`, with tests
pinning the new frame timings.
