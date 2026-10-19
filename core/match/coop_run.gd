class_name CoopRun
extends RefCounted
## Co-op run flow (MatchConfig.Mode.COOP, SPEC.md §2/§6), owned by the
## MatchDirector (`director.coop`, null in versus) and saved with it.
##
## One run, no rounds: team 0 (config.players: humans + optional CPU ally)
## against team 1 enemies the run spawns itself through
## MatchDirector.spawn_fighter. `_queue` enemies are still to come; at most
## Tuning.coop.field_cap fighters (both teams, KO'd enemies until removed)
## are on the field. A freed slot is refilled after refill_delay_frames; a
## KO'd enemy lingers enemy_fade_frames, then is removed. New enemies appear
## on the ring edge farthest from team 0 and play their ENTERING state.
##
## Cleared = queue empty and no enemy standing. Lost = every team-0 fighter at
## 0 HP (DOWNED / OUT / KO all have health 0) or the run timer ran out (the
## director owns the timer). Waves (milestone 4) hook in at
## `_enemies_for_wave` / `_on_field_cleared`.

const HUMAN_TEAM := 0
const ENEMY_TEAM := 1

var director: MatchDirector
var cfg: CoopConfig

## Enemies of the current wave not spawned yet.
var _queue: int = 0
## Slot for the next spawned enemy (never reused).
var _next_slot: int = 0
## Frames until the next refill spawn; -1 = no refill pending.
var _refill_wait: int = -1
## Slot -> frames left before a KO'd enemy is removed.
var _fading: Dictionary = {}
## Current wave index (Brawl: always 0).
var wave: int = 0
var _ended := false
## Last value sent with enemies_left_changed (-1 = none yet).
var _last_left: int = -1
var _rng := RandomNumberGenerator.new()


func _init(p_director: MatchDirector) -> void:
	director = p_director
	cfg = director.config.coop if director.config.coop != null else CoopConfig.new()
	_rng.seed = director.config.rng_seed
	for p in director.config.players:
		_next_slot = maxi(_next_slot, p.slot + 1)


## Most fighters this config can have on the field at once (sizes the arena).
static func planned_field_size(config: MatchConfig) -> int:
	var c := config.coop if config.coop != null else CoopConfig.new()
	var enemies := c.enemy_count
	if c.structure == CoopConfig.Structure.WAVES:
		for w in c.waves:
			enemies = maxi(enemies, w.count)
		if c.endless:
			enemies = maxi(enemies, Tuning.coop.endless_max_count)
	return mini(Tuning.coop.field_cap, config.players.size() + enemies)


## Team-0 start transform for the i-th of n teammates: around the centre at
## human_spawn_radius, facing outward (enemies come from the ring edge).
static func human_transform(i: int, n: int) -> Transform3D:
	var a := TAU * i / maxi(n, 1)
	var radial := Vector3(sin(a), 0.0, cos(a))
	return Transform3D(Basis.looking_at(radial), radial * Tuning.coop.human_spawn_radius)


## Run start (after team 0 is placed): fill the field from the first wave.
func start() -> void:
	_ended = false
	wave = 0
	_queue = _enemies_for_wave(wave)
	_refill_wait = -1
	var k := 0
	while _queue > 0 and director.fighters.size() < Tuning.coop.field_cap:
		_spawn_enemy(k)
		k += 1
	for f in director.fighters:
		if f.team == HUMAN_TEAM:
			f.target = director.pick_default_target(f)
	_emit_left()


## Once per FIGHT tick, before the director's time-out check.
func tick_fight() -> void:
	if _ended:
		return
	_tick_fades()
	_tick_refill()
	_emit_left()
	if _queue == 0 and _alive(ENEMY_TEAM) == 0:
		_on_field_cleared()
	elif _alive(HUMAN_TEAM) == 0:
		_finish(false)


## Enemies still to beat: queued + standing on the field.
func enemies_left() -> int:
	return _queue + _alive(ENEMY_TEAM)


func is_ended() -> bool:
	return _ended


# --- internals -----------------------------------------------------------------

## Enemy count of wave `i`. Brawl: the whole run is wave 0.
func _enemies_for_wave(_i: int) -> int:
	return cfg.enemy_count


## Every enemy of the current wave is down. Brawl: the run is cleared.
## (Waves: start the breather / next wave here.)
func _on_field_cleared() -> void:
	_finish(true)


func _finish(cleared: bool) -> void:
	_ended = true
	director._end_run(cleared)


func _tick_fades() -> void:
	for f in director.fighters.duplicate():
		if f.team != ENEMY_TEAM or not f.is_ko():
			continue
		if not _fading.has(f.slot):
			_fading[f.slot] = Tuning.coop.enemy_fade_frames
		_fading[f.slot] -= 1
		if _fading[f.slot] <= 0:
			_fading.erase(f.slot)
			director.remove_fighter(f)


func _tick_refill() -> void:
	if _queue <= 0 or director.fighters.size() >= Tuning.coop.field_cap:
		_refill_wait = -1
		return
	if _refill_wait < 0:
		_refill_wait = Tuning.coop.refill_delay_frames  # counted from the next tick
		return
	if _refill_wait > 0:
		_refill_wait -= 1
		return
	_refill_wait = -1
	_spawn_enemy(0)


## Spawn one queued enemy; `k` spreads several spawned on the same tick.
func _spawn_enemy(k: int) -> void:
	_queue -= 1
	var slot := _next_slot
	_next_slot += 1
	var character := cfg.enemy_character
	if character == &"":
		var ids := CharacterRegistry.ids()
		character = ids[_rng.randi_range(0, ids.size() - 1)]
	var level := cfg.enemy_level if cfg.enemy_level >= 0 else Tuning.cpu.default_level
	var f := director.spawn_fighter(slot, character, level, ENEMY_TEAM)
	if f == null:
		return
	f.reset_for_round(_edge_transform(k))
	f.target = director.pick_default_target(f)
	f.begin_entry(Tuning.coop.entry_frames)


## On the ring edge, on the far side from team 0's centroid; the k-th spawn
## of a burst alternates sides by spawn_spread_degrees. Faces the centre.
func _edge_transform(k: int) -> Transform3D:
	var c := Vector3.ZERO
	var n := 0
	for f in director.fighters:
		if f.team == HUMAN_TEAM:
			c += f.global_position
			n += 1
	var away := Vector3.FORWARD
	if n > 0:
		c /= n
		var flat := Vector3(-c.x, 0.0, -c.z)
		if flat.length() > 0.001:
			away = flat.normalized()
	var t := Tuning.coop
	var step := deg_to_rad(t.spawn_spread_degrees) * ((k + 1) >> 1) * (1.0 if k % 2 == 1 else -1.0)
	var a := atan2(away.x, away.z) + step
	var dir := Vector3(sin(a), 0.0, cos(a))
	var r := director.arena_radius - Tuning.fighter.body_radius - t.spawn_edge_inset
	return Transform3D(Basis.looking_at(-dir), dir * r)


func _alive(team: int) -> int:
	var n := 0
	for f in director.fighters:
		if f.team == team and not f.is_ko():
			n += 1
	return n


func _emit_left() -> void:
	var left := enemies_left()
	if left != _last_left:
		_last_left = left
		director.enemies_left_changed.emit(left)


func save_state() -> Dictionary:
	return {
		"queue": _queue, "next_slot": _next_slot, "refill_wait": _refill_wait,
		"fading": _fading.duplicate(), "wave": wave, "ended": _ended,
		"last_left": _last_left, "rng": _rng.state,
	}


func load_state(s: Dictionary) -> void:
	_queue = s["queue"]
	_next_slot = s["next_slot"]
	_refill_wait = s["refill_wait"]
	_fading = s["fading"].duplicate()
	wave = s["wave"]
	_ended = s["ended"]
	_last_left = s["last_left"]
	_rng.state = s["rng"]
