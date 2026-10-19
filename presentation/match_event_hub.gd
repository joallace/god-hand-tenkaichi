class_name MatchEventHub
extends Node
## The presentation layer's single view of sim events (SPEC_ONLINE.md §9).
## Funnels every watched fighter's `event` / `state_changed` signals and the
## director's flow signals into two streams, so presentation is correct when
## an online rollback re-simulates ticks it has already shown:
##
## IMMEDIATE (cosmetic) — `fighter_event`, `fighter_state`, `director_event`.
##   For VFX, SFX, camera shakes / FOV punches, HUD flashes and callouts.
##   Every event gets a key (tick, sim_id, kind, n) where tick = director.tick
##   at emission, sim_id = the emitting fighter's (0 for the director) and n
##   numbers same-kind events of one emitter within one tick. A key is emitted
##   at most once. While `director.resimulating` events are recorded but not
##   emitted, except a key never seen before whose tick is within
##   Tuning.net.late_fx_window of the presented tick: it plays late (a hit the
##   correction revealed). Events a rollback erased stay played (accepted
##   "ghost" spark / sound). Keys older than the window are forgotten.
##   Hits reported twice with identical content in one tick show once.
##
## CONFIRMED — `confirmed_event(tick, kind, data)`.
##   For match flow and stats: RunStats, results / scene transitions, round /
##   match / run / wave banners and their sounds. Events are buffered per tick
##   and only emitted once their tick is confirmed, in tick order, so a
##   mispredicted KO never ends the match. Fighter events carry a copy of the
##   payload plus "slot", "team", "sim_id" (the fighter node may be gone by
##   then); director events carry "sim_id" 0.
##   Offline (`auto_confirm` = true, the default) every event is confirmed the
##   moment it happens: same order and timing as the immediate stream.
##
## Director signals captured (`bind_director`; data keys in brackets):
##   &"round_started" [round_number], &"phase_changed" [phase],
##   &"round_ended" [winner_slot, reason], &"match_ended" [winner_slot],
##   &"run_ended" [cleared], &"wave_started" [wave, total],
##   &"wave_cleared" [wave, last] (total / last read when emitted).
## Structural signals (fighters_spawned, entity_spawned / entity_removed) are
## not events: listeners connect to the director directly, and the hub uses
## them to watch / unwatch fighters. State-shaped things (timer, enemies left,
## health / ki bars, the ki charge loop) are read from sim state instead.
##
## ROLLBACK DRIVER API (online; offline nothing calls these):
##   hub.auto_confirm = false            once, before director.setup()
##   per rollback to first wrong tick t:
##     hub.rollback_to(t)                BEFORE director.load_state(snap[t-1]):
##                                       drops buffered events >= t, records the
##                                       presented tick, and ignores the signals
##                                       the load itself fires (ticks < t)
##     director.load_state(...); director.resimulating = true
##     director.step() ... up to the presented tick; resimulating = false
##   hub.confirm_through(tick)           when confirmed_tick reaches `tick`:
##                                       emits buffered events <= tick
## It also remembers each fighter's position at the start of the physics frame
## so effects like teleport can flash at the old location.

signal fighter_event(fighter: Fighter, kind: StringName, data: Dictionary)
## Immediate stream: `fighter` entered state `state_name` (Fighter.state_changed).
signal fighter_state(fighter: Fighter, state_name: StringName)
## Immediate stream: a captured director signal (kinds in the header).
signal director_event(kind: StringName, data: Dictionary)
## Confirmed stream (see header).
signal confirmed_event(tick: int, kind: StringName, data: Dictionary)

const DIRECTOR_SIM_ID := 0
const KIND_STATE := &"state"

## Offline: every event is confirmed immediately. The rollback driver sets it
## false and calls rollback_to / confirm_through.
var auto_confirm := true
## Highest tick whose events went out on confirmed_event.
var confirmed_tick := -1
var director: MatchDirector
var fighters: Array[Fighter] = []
var _last_pos: Dictionary = {}  # Fighter -> Vector3 (start of physics frame)
## Highest tick shown outside a resim (late-FX window reference).
var _presented_tick := -1
## Signals fired at or before this tick come from a load_state, not a step.
var _floor_tick := -1
## tick -> {key: true}: immediate-stream keys seen (kept across resims).
var _seen: Dictionary = {}
## tick -> {"n": {"sim_id|kind": count}, "hits": {content: true}} for the
## current pass over that tick (cleared when a rollback re-runs it).
var _pass: Dictionary = {}
## Unconfirmed events, in arrival (= tick) order: [tick, kind, data].
var _pending: Array = []


func _init() -> void:
	name = "MatchEventHub"
	# Run before the MatchDirector ticks so _last_pos is the pre-tick position.
	process_physics_priority = -100


## Capture `d`'s flow signals and follow its fighters. Call before
## d.setup() so the first round / phase is seen. Safe to call again.
func bind_director(d: MatchDirector) -> void:
	if director == d:
		return
	director = d
	d.fighters_spawned.connect(watch)
	d.entity_spawned.connect(_on_entity_spawned)
	d.entity_removed.connect(_on_entity_removed)
	d.round_started.connect(func(n: int) -> void: _director(&"round_started", {"round_number": n}))
	d.phase_changed.connect(func(p: MatchDirector.Phase) -> void: _director(&"phase_changed", {"phase": p}))
	d.round_ended.connect(func(w: int, r: StringName) -> void:
		_director(&"round_ended", {"winner_slot": w, "reason": r}))
	d.match_ended.connect(func(w: int) -> void: _director(&"match_ended", {"winner_slot": w}))
	d.run_ended.connect(func(c: bool) -> void: _director(&"run_ended", {"cleared": c}))
	d.wave_started.connect(func(w: int) -> void:
		_director(&"wave_started", {"wave": w, "total": d.coop.wave_total() if d.coop != null else -1}))
	d.wave_cleared.connect(func(w: int) -> void:
		_director(&"wave_cleared", {"wave": w, "last": d.coop != null and d.coop.is_last_wave()}))


## `p_fighters` is the director's live array (it changes in place when
## fighters join or leave); fighters added later are hooked by watch_fighter.
func watch(p_fighters: Array[Fighter]) -> void:
	fighters = p_fighters
	for f in fighters:
		watch_fighter(f)


## Hook one fighter's events (a fighter spawned mid-match or rebuilt by a
## load). Freed fighters disconnect on their own.
func watch_fighter(f: Fighter) -> void:
	if _last_pos.has(f):
		return
	_last_pos[f] = f.global_position
	f.event.connect(_on_event.bind(f))
	f.state_changed.connect(_on_state_changed.bind(f))


## Forget a fighter that is leaving the match (its signal goes with the node).
func unwatch_fighter(f: Fighter) -> void:
	_last_pos.erase(f)


func last_position(f: Fighter) -> Vector3:
	return _last_pos.get(f, f.global_position)


# --- rollback driver API ---------------------------------------------------------

## A rollback will re-simulate from `tick` (see header for the call order).
func rollback_to(tick: int) -> void:
	var d := director
	if d != null:
		_presented_tick = maxi(_presented_tick, d.tick)
	if tick <= confirmed_tick:
		push_error("MatchEventHub.rollback_to(%d): tick %d is already confirmed" % [tick, confirmed_tick])
	_floor_tick = tick - 1
	var kept: Array = []
	for rec: Array in _pending:
		if int(rec[0]) < tick:
			kept.append(rec)
	_pending = kept
	for t: int in _pass.keys():
		if t >= tick:
			_pass.erase(t)


## Every tick <= `tick` is final: emit its buffered events in tick order.
func confirm_through(tick: int) -> void:
	if tick <= confirmed_tick:
		return
	confirmed_tick = tick
	var rest: Array = []
	var out: Array = []
	for rec: Array in _pending:
		if int(rec[0]) <= tick:
			out.append(rec)
		else:
			rest.append(rec)
	_pending = rest
	for rec: Array in out:
		confirmed_event.emit(int(rec[0]), rec[1], rec[2])


## Events recorded but not yet confirmed (tests / diagnostics).
func pending_count() -> int:
	return _pending.size()


# --- internals -------------------------------------------------------------------

func _physics_process(_delta: float) -> void:
	for f in fighters:
		if is_instance_valid(f) and f.is_inside_tree():
			_last_pos[f] = f.global_position
	if director != null and not director.resimulating:
		_presented(director.tick)


func _on_entity_spawned(e: SimEntity) -> void:
	if e is Fighter:
		watch_fighter(e as Fighter)


func _on_entity_removed(e: SimEntity) -> void:
	if e is Fighter:
		unwatch_fighter(e as Fighter)


func _director_of(f: Fighter) -> MatchDirector:
	if director != null:
		return director
	return f.director if f != null else null


func _on_event(kind: StringName, data: Dictionary, f: Fighter) -> void:
	var d := _director_of(f)
	var tick := d.tick if d != null else Engine.get_physics_frames()
	if tick <= _floor_tick:
		return
	# The same hit may be reported twice in a tick; show it once.
	if kind == &"hit":
		var hits: Dictionary = _pass_for(tick)["hits"]
		var key := "%s|%s|%s" % [data.get("attacker_slot", -1), data.get("position", Vector3.INF), data.get("damage", 0)]
		if hits.has(key):
			return
		hits[key] = true
	if _admit(d, tick, f.sim_id, kind):
		fighter_event.emit(f, kind, data)
	var c := data.duplicate()
	c["slot"] = f.slot
	c["team"] = f.team
	c["sim_id"] = f.sim_id
	_confirm_later(tick, kind, c)


func _on_state_changed(state_name: StringName, f: Fighter) -> void:
	var d := _director_of(f)
	var tick := d.tick if d != null else Engine.get_physics_frames()
	if tick <= _floor_tick:
		return
	if _admit(d, tick, f.sim_id, KIND_STATE):
		fighter_state.emit(f, state_name)


func _director(kind: StringName, data: Dictionary) -> void:
	var tick := director.tick
	if tick <= _floor_tick:
		return
	if _admit(director, tick, DIRECTOR_SIM_ID, kind):
		director_event.emit(kind, data)
	var c := data.duplicate()
	c["sim_id"] = DIRECTOR_SIM_ID
	_confirm_later(tick, kind, c)


## Immediate-stream gate: records the key and says whether to emit it now.
func _admit(d: MatchDirector, tick: int, sim_id: int, kind: StringName) -> bool:
	var counts: Dictionary = _pass_for(tick)["n"]
	var ck := "%d|%s" % [sim_id, kind]
	var n: int = counts.get(ck, 0)
	counts[ck] = n + 1
	var resim := d != null and d.resimulating
	if not resim:
		_presented(tick)
	var oldest := _presented_tick - Tuning.net.late_fx_window
	if tick < oldest:
		return false  # too old to show (and never shown again)
	var seen: Dictionary = _seen.get(tick, {})
	var key := "%s|%d" % [ck, n]
	if seen.has(key):
		return false
	seen[key] = true
	_seen[tick] = seen
	return true


func _pass_for(tick: int) -> Dictionary:
	var p: Dictionary = _pass.get(tick, {})
	if p.is_empty():
		p = {"n": {}, "hits": {}}
		_pass[tick] = p
	return p


## Advance the presented tick and forget keys that can no longer play.
func _presented(tick: int) -> void:
	if tick <= _presented_tick:
		return
	_presented_tick = tick
	var oldest := _presented_tick - Tuning.net.late_fx_window
	for t: int in _seen.keys():
		if t < oldest:
			_seen.erase(t)
	for t: int in _pass.keys():
		if t < oldest:
			_pass.erase(t)


func _confirm_later(tick: int, kind: StringName, data: Dictionary) -> void:
	if auto_confirm:
		confirmed_tick = maxi(confirmed_tick, tick)
		confirmed_event.emit(tick, kind, data)
	else:
		_pending.append([tick, kind, data])


## Fighter that receives the hit described by a &"hit" event emitted by `f`.
func hit_victim(f: Fighter, data: Dictionary) -> Fighter:
	var attacker_slot: int = data.get("attacker_slot", -1)
	if attacker_slot == f.slot and f.target != null:
		return f.target
	return f


## World position for an event: payload `position` if present, else fighter.
func event_position(f: Fighter, data: Dictionary, height: float) -> Vector3:
	var p: Variant = data.get("position")
	if p is Vector3:
		return p
	return f.global_position + Vector3.UP * height
