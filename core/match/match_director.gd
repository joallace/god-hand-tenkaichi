class_name MatchDirector
extends Node3D
## Owns the fixed-tick simulation and round flow. Mode-agnostic: it only knows
## a MatchConfig, InputSources and SimEntities.
##
## Per tick:
##   1. poll every InputSource once (always, even in hitstop/intro)
##   2. feed frames to fighters (they buffer them)
##   3. unless the world is frozen: sim_tick fighters (slot order), then other
##      entities; an entity in its own hitstop counts it down instead
##   4. CombatSystem.resolve() - hitbox vs hurtbox, applies hits
##   5. round timer / KO checks
##
## Hitstop is per entity: a contact freezes only the attacker, the victim and
## the hitting entity (request_hitstop); everyone else keeps simulating. A few
## effects (ultimate, counter guard, push-stop) freeze the whole world instead
## (request_world_freeze), which also pauses the round timer.
##
## Presentation (cameras, HUD, VFX) only observes signals and node transforms.

signal fighters_spawned(fighters: Array[Fighter])
signal phase_changed(phase: Phase)
signal round_started(round_number: int)
## winner_slot = -1 on draw. reason: &"ko", &"time", &"draw"
signal round_ended(winner_slot: int, reason: StringName)
signal match_ended(winner_slot: int)
signal timer_changed(seconds_left: int)  # -1 when infinite
signal pause_requested(slot: int)
## A sim entity (fighter or projectile) joined / is about to leave the match:
## spawned, freed, or rebuilt / dropped by load_state. Fighters created by
## setup() are announced by fighters_spawned instead.
signal entity_spawned(e: SimEntity)
signal entity_removed(e: SimEntity)

enum Phase { NONE, INTRO, FIGHT, OUTRO, MATCH_OVER }

var config: MatchConfig
var fighters: Array[Fighter] = []
var entities: Array[SimEntity] = []  # non-fighter entities (projectiles...)
var combat: CombatSystem
var sources: Array[InputSource] = []

var tick: int = 0
var phase: Phase = Phase.NONE
var phase_frames: int = 0
var round_number: int = 0
var round_frames_left: int = 0
var wins: PackedInt32Array = PackedInt32Array()
## Frames the whole sim stays frozen (ultimate, counter guard, push-stop).
var world_freeze: int = 0
## Next SimEntity.sim_id. Ids are never reused within a match, so snapshots
## name entities unambiguously; fighters, then entities, tick in id order.
var next_sim_id: int = 1
## When true the sim does not advance (pause menu). Inputs aren't polled.
## On unpause, sources resync so buttons still held from the menu (e.g. the
## A that pressed "Resume") don't register as fresh presses.
var paused := false:
	set(value):
		if paused and not value:
			for s in sources:
				s.resync(tick)
		paused = value
## Set false to drive `step()` manually (tests, rollback re-simulation).
var auto_step := true

var _last_second_emitted := -2


func setup(p_config: MatchConfig) -> void:
	config = p_config
	combat = CombatSystem.new(self)
	wins.resize(config.players.size())
	wins.fill(0)
	for p in config.players:
		var src := p.create_input_source()
		src.attach(self, p.slot)
		sources.append(src)
		var f := EntityFactory.create_fighter(p.slot, p.character_id, _config_team(p))
		f.sim_id = _take_sim_id()
		add_child(f)
		f.director = self
		fighters.append(f)
	if fighters.size() == 2:
		fighters[0].opponent = fighters[1]
		fighters[1].opponent = fighters[0]
	fighters_spawned.emit(fighters)
	_start_round()


func _physics_process(_delta: float) -> void:
	if auto_step and not paused and phase != Phase.NONE:
		step()


func step() -> void:
	tick += 1
	var neutral := InputFrame.new()
	for i in fighters.size():
		var frame := sources[i].poll(tick)
		if frame.just_pressed(InputFrame.Btn.PAUSE) and phase == Phase.FIGHT:
			pause_requested.emit(fighters[i].slot)
		fighters[i].feed_input(frame if phase == Phase.FIGHT else neutral)

	if world_freeze > 0:
		world_freeze -= 1
	else:
		for f in fighters:
			_tick_entity(f)
		for e in entities.duplicate():
			_tick_entity(e)
		combat.resolve(tick)
		_reap_entities()

	phase_frames += 1
	match phase:
		Phase.INTRO:
			if phase_frames >= Tuning.match_rules.round_intro_frames:
				_set_phase(Phase.FIGHT)
				for f in fighters:
					f.set_control_enabled(true)
		Phase.FIGHT:
			_tick_fight()
		Phase.OUTRO:
			if phase_frames >= Tuning.match_rules.round_outro_frames:
				_after_round()


func _tick_entity(e: SimEntity) -> void:
	if e.hitstop > 0:
		e.hitstop -= 1
	else:
		e.sim_tick(tick)


func _tick_fight() -> void:
	if not config.is_infinite_time() and world_freeze == 0:
		round_frames_left -= 1
		_emit_timer()
	var ko: Array[Fighter] = fighters.filter(func(f: Fighter) -> bool: return f.is_ko())
	if not ko.is_empty():
		var winner := -1
		if ko.size() == 1:
			winner = fighters[1 - fighters.find(ko[0])].slot
		_end_round(winner, &"ko" if winner >= 0 else &"draw")
	elif not config.is_infinite_time() and round_frames_left <= 0:
		var a := fighters[0].health_ratio()
		var b := fighters[1].health_ratio()
		var winner := -1 if is_equal_approx(a, b) else (fighters[0].slot if a > b else fighters[1].slot)
		_end_round(winner, &"time" if winner >= 0 else &"draw")


func _start_round() -> void:
	round_number += 1
	world_freeze = 0
	for e in entities:
		_free_node(e)
	entities.clear()
	round_frames_left = config.round_time_seconds * Tuning.match_rules.tick_rate
	var d := Tuning.match_rules.spawn_distance * 0.5
	for i in fighters.size():
		var pos := Vector3(0, 0, d if i == 0 else -d)
		fighters[i].reset_for_round(Transform3D(Basis.looking_at(-pos.normalized()), pos))
		fighters[i].set_control_enabled(false)
	for s in sources:
		s.reset()
	_last_second_emitted = -2
	_emit_timer()
	_set_phase(Phase.INTRO)
	round_started.emit(round_number)


func _end_round(winner_slot: int, reason: StringName) -> void:
	for f in fighters:
		f.set_control_enabled(false)
	if winner_slot >= 0:
		wins[winner_slot] += 1
	_set_phase(Phase.OUTRO)
	round_ended.emit(winner_slot, reason)


func _after_round() -> void:
	for slot in wins.size():
		if wins[slot] >= config.rounds_to_win:
			_set_phase(Phase.MATCH_OVER)
			match_ended.emit(slot)
			return
	_start_round()


func _set_phase(p: Phase) -> void:
	phase = p
	phase_frames = 0
	phase_changed.emit(p)


func _emit_timer() -> void:
	var s := -1 if config.is_infinite_time() else ceili(maxi(round_frames_left, 0) / float(Tuning.match_rules.tick_rate))
	if s != _last_second_emitted:
		_last_second_emitted = s
		timer_changed.emit(s)


# --- API for entities --------------------------------------------------------

## Freeze only `participants` (Fighters / SimEntities) for `frames` ticks.
func request_hitstop(participants: Array, frames: int) -> void:
	for e: SimEntity in participants:
		if e != null:
			e.hitstop = maxi(e.hitstop, frames)


## Freeze the whole simulation (and the round timer) for `frames` ticks.
func request_world_freeze(frames: int) -> void:
	world_freeze = maxi(world_freeze, frames)


## Register a new non-fighter entity (projectile, beam). It ticks after every
## entity spawned before it.
func spawn_entity(e: SimEntity) -> void:
	e.director = self
	e.sim_id = _take_sim_id()
	add_child(e)
	entities.append(e)
	entity_spawned.emit(e)


func _reap_entities() -> void:
	for e in entities.duplicate():
		if e.sim_dead:
			entities.erase(e)
			_free_node(e)


func fighter_for_slot(slot: int) -> Fighter:
	for f in fighters:
		if f.slot == slot:
			return f
	return null


## Live fighter or entity with this sim_id, or null.
func entity_by_id(id: int) -> SimEntity:
	for f in fighters:
		if f.sim_id == id:
			return f
	for e in entities:
		if e.sim_id == id:
			return e
	return null


# --- dynamic fighters ----------------------------------------------------------
#
# A fighter that joins mid-match (co-op waves) is CPU controlled: its init's
# cpu_level >= 0 marks it, and its CpuInput is created with it here (or by
# load_state when a snapshot needs it back), lives at the same index in
# `sources`, is saved in "sources" like every other source, and is dropped
# with it. Fighters from the MatchConfig rebuild their source from their
# PlayerSlotConfig if a load ever has to recreate them.

## Add a CPU fighter for `slot` (must be unused) mid-match. The caller places
## it (reset_for_round). Control follows the phase.
func spawn_fighter(slot: int, character_id: StringName, cpu_level: int, team: int = -1) -> Fighter:
	if fighter_for_slot(slot) != null:
		push_error("MatchDirector.spawn_fighter: slot %d already has a fighter" % slot)
		return null
	var f := EntityFactory.create(EntityFactory.fighter_desc(slot, character_id, team, maxi(cpu_level, 0))) as Fighter
	f.sim_id = _take_sim_id()
	_add_fighter(f, _source_for(f))
	f.set_control_enabled(phase == Phase.FIGHT)
	entity_spawned.emit(f)
	return f


## Take a fighter (and its input source) out of the match. Projectiles it
## cast go with it; nobody keeps a reference to it.
func remove_fighter(f: Fighter) -> void:
	var i := fighters.find(f)
	if i < 0:
		return
	fighters.remove_at(i)
	sources.remove_at(i)
	for e in entities.duplicate():
		if e.get("caster") == f:
			entities.erase(e)
			_free_node(e)
	_free_node(f)
	_forget_removed_fighters()


func _add_fighter(f: Fighter, src: InputSource) -> void:
	add_child(f)
	f.director = self
	fighters.append(f)
	src.attach(self, f.slot)
	sources.append(src)


func _source_for(f: Fighter) -> InputSource:
	var level: int = f.spawn_init.get("cpu_level", -1)
	if level >= 0:
		return CpuInput.new(level)
	for p in config.players:
		if p.slot == f.slot:
			return p.create_input_source()
	return CpuInput.new(-1)


## Drop links to fighters that left `fighters` (freed nodes must not be read).
## CPU brains re-resolve their fighters lazily.
func _forget_removed_fighters() -> void:
	for f in fighters:
		if f.opponent != null and not fighters.has(f.opponent):
			f.opponent = null
	for src in sources:
		var cpu := src as CpuInput
		if cpu != null and not (fighters.has(cpu.brain.me) and fighters.has(cpu.brain.opp)):
			cpu.brain.me = null
			cpu.brain.opp = null


func _take_sim_id() -> int:
	next_sim_id += 1
	return next_sim_id - 1


func _config_team(p: PlayerSlotConfig) -> int:
	var t: Variant = p.get("team")
	return t if t is int else -1


func _free_node(e: SimEntity) -> void:
	entity_removed.emit(e)
	if e.get_parent() == self:
		remove_child(e)
	e.queue_free()


## Snapshot for rollback: every live entity's spawn descriptor and state, so
## load_state can rebuild entities spawned or freed since. Sources are saved
## in fighter order.
func save_state() -> Dictionary:
	return {
		"tick": tick, "phase": phase, "phase_frames": phase_frames,
		"round_number": round_number, "round_frames_left": round_frames_left,
		"wins": wins.duplicate(), "world_freeze": world_freeze, "next_sim_id": next_sim_id,
		"fighters": fighters.map(func(f: Fighter) -> Dictionary: return {"desc": f.spawn_desc(), "state": f.save_state()}),
		"sources": sources.map(func(src: InputSource) -> Dictionary: return src.save_state()),
		"entities": entities.map(func(e: SimEntity) -> Dictionary: return {"desc": e.spawn_desc(), "state": e.save_state()}),
	}


func load_state(s: Dictionary) -> void:
	tick = s["tick"]
	phase = s["phase"]
	phase_frames = s["phase_frames"]
	round_number = s["round_number"]
	round_frames_left = s["round_frames_left"]
	wins = s["wins"].duplicate()
	world_freeze = s["world_freeze"]
	next_sim_id = s["next_sim_id"]
	var created: Array[SimEntity] = []
	_restore_fighters(s["fighters"], s["sources"], created)
	_restore_entities(s["entities"], created)
	for e in created:
		entity_spawned.emit(e)


## Make `fighters`/`sources` match the snapshot: drop fighters it doesn't
## have, rebuild the ones it has that are gone (each with a fresh source),
## keep the rest (and their source objects), in snapshot order. Arrays are
## changed in place: presentation holds references to them.
func _restore_fighters(records: Array, source_states: Array, created: Array[SimEntity]) -> void:
	var wanted := {}
	for r: Dictionary in records:
		wanted[r["desc"]["id"]] = true
	var by_id := {}
	for i in fighters.size():
		var f := fighters[i]
		if wanted.has(f.sim_id):
			by_id[f.sim_id] = [f, sources[i]]
		else:
			_free_node(f)
	var new_fighters: Array[Fighter] = []
	var new_sources: Array[InputSource] = []
	for r: Dictionary in records:
		var id: int = r["desc"]["id"]
		if by_id.has(id):
			new_fighters.append(by_id[id][0])
			new_sources.append(by_id[id][1])
			continue
		var f := EntityFactory.create(r["desc"]) as Fighter
		add_child(f)
		f.director = self
		var src := _source_for(f)
		src.attach(self, f.slot)
		new_fighters.append(f)
		new_sources.append(src)
		created.append(f)
	fighters.clear()
	fighters.append_array(new_fighters)
	sources.clear()
	sources.append_array(new_sources)
	_forget_removed_fighters()
	for i in fighters.size():
		fighters[i].load_state(records[i]["state"])
	for i in sources.size():
		sources[i].load_state(source_states[i])


## Same for projectiles: drop, rebuild through the factory, relink (casters
## exist by now), then load every state.
func _restore_entities(records: Array, created: Array[SimEntity]) -> void:
	var wanted := {}
	for r: Dictionary in records:
		wanted[r["desc"]["id"]] = true
	var by_id := {}
	for e in entities:
		if wanted.has(e.sim_id):
			by_id[e.sim_id] = e
		else:
			_free_node(e)
	entities.clear()
	for r: Dictionary in records:
		var id: int = r["desc"]["id"]
		var e: SimEntity = by_id.get(id)
		if e == null:
			e = EntityFactory.create(r["desc"])
			e.director = self
			add_child(e)
			e.resolve_links(self)
			created.append(e)
		entities.append(e)
	for i in entities.size():
		entities[i].load_state(records[i]["state"])
