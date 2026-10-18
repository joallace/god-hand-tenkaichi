class_name MatchDirector
extends Node3D
## Owns the fixed-tick simulation and round flow. Mode-agnostic: it only knows
## a MatchConfig, InputSources and SimEntities.
##
## Per tick:
##   1. poll every InputSource once (always, even in hitstop/intro)
##   2. feed frames to fighters (they buffer them)
##   3. unless in hitstop: sim_tick fighters (slot order), then other entities
##   4. CombatSystem.resolve() - hitbox vs hurtbox, applies hits
##   5. round timer / KO checks
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
var hitstop: int = 0
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
		var f := CharacterRegistry.create_fighter(p.character_id)
		f.slot = p.slot
		f.name = "Fighter%d" % (p.slot + 1)
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

	if hitstop > 0:
		hitstop -= 1
	else:
		for f in fighters:
			f.sim_tick(tick)
		for e in entities.duplicate():
			e.sim_tick(tick)
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


func _tick_fight() -> void:
	if not config.is_infinite_time() and hitstop == 0:
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
	hitstop = 0
	for e in entities:
		e.queue_free()
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

func request_hitstop(frames: int) -> void:
	hitstop = maxi(hitstop, frames)


func spawn_entity(e: SimEntity) -> void:
	e.director = self
	add_child(e)
	entities.append(e)


func _reap_entities() -> void:
	for e in entities.duplicate():
		if e.sim_dead:
			entities.erase(e)
			e.queue_free()


func fighter_for_slot(slot: int) -> Fighter:
	for f in fighters:
		if f.slot == slot:
			return f
	return null


## Snapshot for rollback. NOTE: spawned/despawned entities are not yet
## reconstructed on load; that's future netcode work (entity factory by type).
func save_state() -> Dictionary:
	return {
		"tick": tick, "phase": phase, "phase_frames": phase_frames,
		"round_number": round_number, "round_frames_left": round_frames_left,
		"wins": wins.duplicate(), "hitstop": hitstop,
		"fighters": fighters.map(func(f: Fighter) -> Dictionary: return f.save_state()),
		"sources": sources.map(func(src: InputSource) -> Dictionary: return src.save_state()),
	}


func load_state(s: Dictionary) -> void:
	tick = s["tick"]
	phase = s["phase"]
	phase_frames = s["phase_frames"]
	round_number = s["round_number"]
	round_frames_left = s["round_frames_left"]
	wins = s["wins"].duplicate()
	hitstop = s["hitstop"]
	for i in fighters.size():
		fighters[i].load_state(s["fighters"][i])
	for i in sources.size():
		sources[i].load_state(s["sources"][i])
