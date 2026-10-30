# Web / mobile performance notes

What we know about the web build's performance, what is already fixed, and
the optimizations still open, ranked by expected impact. Measure before and
after every change with `tools/frame_probe.tscn` (see CLAUDE.md, Tools):

```sh
tools/web_probe.sh mode=fight frames=2400   # CPU vs CPU in Chrome: spikes per combat event
tools/web_probe.sh mode=events              # each VFX/SFX suspect alone: call cost
tools/web_probe.sh mode=bench               # per-call cost of nodes/materials/tweens/audio
```

On a phone or another PC: run `python3 tools/serve_web.py --dir builds/web-probe`
after one `tools/web_probe.sh` export, open `https://<host>:8443/?mode=fight`,
and read the `FRAME_PROBE` lines in the browser console.

## Why the web build is different

- **GDScript is several times slower** (WASM). Work that costs ~0.3 ms per
  frame on desktop can cost several ms in the browser. Per-event allocations
  that desktop never notices can push a 60 Hz frame past 16.6 ms. (The
  sim itself, plain arithmetic GDScript, measured only ~1.6× the native
  release template: `tools/web_tools.sh tool=bench`, SPEC_online.md §12.1.)
- **Single-threaded** (`web_nothreads` templates): sim, scripts, rendering
  and (sample-mode) audio calls all run on the browser's main thread.
- **Compatibility renderer** (WebGL2, `rendering_method.web`): no FSR, no
  pipeline-compilation monitors (they read 0), and shaders compile
  synchronously on first use of each variant.
- **Canvas at native resolution**: the canvas uses `devicePixelRatio`, so a
  phone with a ratio of 3 renders the 3D scene at full panel resolution.

Measured costs in Chrome (AMD Lucienne iGPU, 2026-10; desktop-class machine):

| Call | Cost on web |
|---|---|
| `StandardMaterial3D.duplicate()` | ~0.31 ms |
| `StandardMaterial3D.new()` + a few property sets | ~0.01-0.04 ms |
| `MeshInstance3D.new()` + `add_child` | ~0.02-0.04 ms |
| tween with 2 properties + callback | ~0.015 ms |
| reusing a node: color + position + scale | ~0.003 ms |
| `Sfx.play` (sample playback) | ~0.6-2.3 ms |
| `AudioStreamPlayer.play()`, same stream | ~0.27-0.58 ms |

## Already done

- **Effect shaders kept alive** (`presentation/vfx/fx_materials.gd`): every
  transient material is built with the flags of a session-lifetime template,
  so its shader is never freed and recompiled; `FxMaterials.warm_up()` draws
  each template at match start. Fighter glow varies emission energy and never
  toggles `emission_enabled` (`tests/fx_materials_test` lints this).
- **No `duplicate()` for materials**: `FxMaterials.make()` builds fresh.
- **Pooled hit effects** (`VfxManager`): flashes, sparks and shockwaves reuse
  meshes and materials and animate in `_process`. A heavy hit went from
  3.2-6.7 ms to ~1.6 ms in Chrome; the rest is mostly the hit sound.
- Vanish/reappear flashes share one sphere mesh (`FighterVisual._flash_mesh`).

## Open optimizations

### 1. Lighter video defaults on web (GPU, biggest win on phones)

`core/tuning/video_tuning.gd` defaults apply on every platform:
`default_render_scale = 1.0`, `default_shadow_quality = 2` (HIGH: 4096 atlas,
soft filter quality 2). Add web (or mobile web) defaults and pick them in
`VideoSettings.reset_defaults()` behind a `PlatformCaps` check, e.g.
`OS.has_feature("web_android") or OS.has_feature("web_ios")`, with the values
in `Tuning.video` (no magic numbers). Suggested: render scale 0.5-0.67
(bilinear scaling already works on Compatibility through
`Settings.configure_viewport`; UI stays sharp with `canvas_items` stretch),
shadows OFF or LOW. A saved `user://video.cfg` still overrides them.

### 2. Glow off on web

`presentation/arena/arena.gd` sets `env.glow_enabled = a.glow_enabled`
(`Tuning.arena.glow_enabled = true`). On Compatibility, glow adds several
full-screen downsample/blur passes: costly in fill rate and memory bandwidth
on mobile GPUs. Disable it on web, or make it a Graphics setting.

### 3. MSAA per split-screen viewport

`presentation/view/view_layout.gd` (`_make_view`) hardcodes
`vp.msaa_3d = Viewport.MSAA_2X`. On WebGL2 that is a multisampled framebuffer
plus a resolve per SubViewport. Skip it on web, or tie it to a setting,
especially once the render scale is lowered.

### 4. Cheaper shadows when they stay on

The sun uses `SHADOW_PARALLEL_2_SPLITS` (`arena.gd`): two extra depth passes
over every shadow caster. On web prefer `SHADOW_ORTHOGONAL` (one pass), or
replace shadows with a blob decal under each fighter. Fighters are many
primitive meshes (`FighterVisual._build`), all casting shadows; turning off
casting on small parts (hands, feet boxes, head) cuts shadow draw calls,
which multiplies with the co-op field size. Boulders and pillars cast too
(mountains already don't). Ki blasts and beam segments cast shadows by
default (`ki_blast.gd` `_build_visual`, `beam_visual.gd`); glowing projectiles
probably shouldn't. `FxMaterials.warm_up()` meshes don't cast shadows, so the
first shadow-casting projectile still compiles its shadow-pass variant.

### 5. Hit sounds (~0.6-2 ms per `Sfx.play` on web)

Now the largest per-hit CPU cost on web. Godot plays sounds there as Web
Audio samples (`audio/general/default_playback_type.web` = Sample), and each
`play()` crosses into JavaScript. Ideas, measure each with `mode=events`:
- one `AudioStreamPlayer` per sound id with a fixed stream (and
  `max_polyphony`) instead of swapping `stream`/`bus`/volume on the shared
  voice pool (`presentation/audio/sfx.gd`, `play()` / `_free_voice()`);
  saves the stream swap but not the base `play()` cost (~0.27-0.58 ms);
- cap sounds per frame (a heavy hit plus knockdown plus KO can play several);
- `PLAYBACK_TYPE_STREAM` made `play()` ~0.07 ms in a bench, but then mixing
  runs on the single web thread every frame (constant cost, crackle risk):
  only with a full `mode=fight` comparison.

### 6. Per-spawn allocations in projectiles and dodges

Still allocate on each use (cheap on desktop, worth pooling if `mode=fight`
shows spikes on these events):
- `KiBlast._build_visual()`: new `SphereMesh` (mesh generated per blast) +
  material + `SmoothedVisual` per blast. Cache the mesh per radius.
- `BeamVisual.setup()`: new `CylinderMesh` + head `SphereMesh` + material
  per beam; segment meshes are added as the beam bends.
- `VfxManager.afterimage()` (perfect dodge): one `MeshInstance3D` per fighter
  part plus a tween, every dodge.
- `FighterVisual._spawn_flash()`: new node + material per vanish/reappear
  (mesh is shared now).

### 7. Frame catch-up on slow devices

The director ticks in `_physics_process` (`core/match/match_director.gd`)
with Godot's default `physics/common/max_physics_steps_per_frame` (8). When a
device can't hold 60 fps it runs several sim ticks in one frame, making that
frame slower still. On web (offline only; online needs real-time catch-up
and is disabled on web anyway), a lower cap (2-3) degrades into slow motion
instead of a spiral. Set it per platform with a feature override, e.g.
`physics/common/max_physics_steps_per_frame.web=3` in `project.godot`.

### 8. Minor

- Scenery: each boulder/pillar builds its own mesh (`Arena._build_scenery`);
  sharing a few meshes saves memory and build time at match load.
- The main menu's full-screen animated shader (`ui/animated_background.gd`)
  costs battery on phones; not in the match.
- Co-op KO fade sets `GeometryInstance3D.transparency` on fighter parts
  (`FighterVisual._update_ko_fade`): on first use that needs a transparent
  variant of the body shaders (one compile per session, not per hit).

## Not a performance issue: hitstop

Hits freeze attacker and victim 4 (light) / 8 (heavy) ticks, ki blasts 3,
and beam/ultimate ticks freeze both fighters 1 tick every 5-6 ticks
(`hitstop` in `tools/generate_moves.gd`). This is identical on desktop, so
it isn't the web stutter, but 1-3 tick freezes can read as dropped frames.
Game-feel options, undecided: jitter the victim's drawn body during the
freeze (presentation only), skip hitstop on beam ticks / remote projectile
casters, or BT3 style (little or no melee hitstop, camera shake instead; see
`docs/bt3_reference.md` and `docs/reference_mechanics.md` "Hitstop review").
