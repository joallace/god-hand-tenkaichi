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
## Teams: every fighter has a team (PlayerSlotConfig.team, default = slot, so
## 1v1 is two teams of one). A round ends when at most one team has a fighter
## standing; on time-out the team with the best mean health ratio wins.
## `wins` is indexed by TEAM; round_ended/match_ended still carry a winner
## slot (the lowest slot of the winning team, -1 = draw) and
## `last_winner_team` holds the team. Each fighter's `target` is picked by
## pick_default_target() (nearest standing enemy).
##
## Presentation (cameras, HUD, VFX) only observes signals and node transforms.

signal fighters_spawned(fighters: Array[Fighter])
signal phase_changed(phase: Phase)
signal round_started(round_number: int)
## winner_slot = -1 on draw (lowest slot of the winning team otherwise; the
## team is in last_winner_team). reason: &"ko", &"time", &"draw"
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
## Rounds won, indexed by team id.
var wins: PackedInt32Array = PackedInt32Array()
## Team that won the last round (-1 = draw / none yet).
var last_winner_team: int = -1
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
	var max_team := 0
	for p in config.players:
		max_team = maxi(max_team, p.team if p.team >= 0 else p.slot)
	wins.resize(max_team + 1)
	wins.fill(0)
	for p in config.players:
		var src := p.create_input_source()
		src.attach(self, p.slot)
		sources.append(src)
		var f := CharacterRegistry.create_fighter(p.character_id)
		f.slot = p.slot
		f.team = p.team if p.team >= 0 else p.slot
		f.name = "Fighter%d" % (p.slot + 1)
		add_child(f)
		f.director = self
		fighters.append(f)
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
	var standing := _standing_teams()
	if standing.size() < _teams().size():
		if standing.size() <= 1:
			var winner := standing[0] if standing.size() == 1 else -1
			_end_round(winner, &"ko" if winner >= 0 else &"draw")
			return
	if not config.is_infinite_time() and round_frames_left <= 0:
		var winner := _best_health_team()
		_end_round(winner, &"time" if winner >= 0 else &"draw")
		return
	_update_targets()


func _start_round() -> void:
	round_number += 1
	hitstop = 0
	for e in entities:
		e.queue_free()
	entities.clear()
	round_frames_left = config.round_time_seconds * Tuning.match_rules.tick_rate
	for i in fighters.size():
		fighters[i].reset_for_round(spawn_transform(i))
		fighters[i].set_control_enabled(false)
	for f in fighters:
		f.target = pick_default_target(f)
	for s in sources:
		s.reset()
	_last_second_emitted = -2
	_emit_timer()
	_set_phase(Phase.INTRO)
	round_started.emit(round_number)


func _end_round(winner_team: int, reason: StringName) -> void:
	for f in fighters:
		f.set_control_enabled(false)
	last_winner_team = winner_team
	if winner_team >= 0:
		wins[winner_team] += 1
	_set_phase(Phase.OUTRO)
	round_ended.emit(team_lead_slot(winner_team), reason)


func _after_round() -> void:
	for team in wins.size():
		if wins[team] >= config.rounds_to_win:
			_set_phase(Phase.MATCH_OVER)
			match_ended.emit(team_lead_slot(team))
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


# --- Teams ---------------------------------------------------------------------

## Default target policy: the nearest standing fighter of another team (ties:
## lowest slot), or null if there is none. One place to swap the policy.
func pick_default_target(f: Fighter) -> Fighter:
	var best: Fighter = null
	var best_d := INF
	for o in fighters:
		if o.team == f.team or o.is_ko():
			continue
		var d := f.global_position.distance_squared_to(o.global_position)
		if d < best_d:
			best = o
			best_d = d
	return best


## Re-pick for every standing fighter whose target is gone or KO'd (keeps the
## old one when no enemy stands, e.g. the round is ending).
func _update_targets() -> void:
	for f in fighters:
		if f.is_ko() or (f.target != null and not f.target.is_ko()):
			continue
		var t := pick_default_target(f)
		if t != null:
			f.target = t


## Team ids present, ascending.
func _teams() -> Array[int]:
	var out: Array[int] = []
	for f in fighters:
		if not f.team in out:
			out.append(f.team)
	out.sort()
	return out


## Teams with at least one fighter not KO'd, ascending.
func _standing_teams() -> Array[int]:
	var out: Array[int] = []
	for f in fighters:
		if not f.is_ko() and not f.team in out:
			out.append(f.team)
	out.sort()
	return out


## Time-out winner: highest mean health ratio of a team's fighters; -1 on a tie.
func _best_health_team() -> int:
	var best := -1
	var best_ratio := -1.0
	var tie := false
	for team in _teams():
		var sum := 0.0
		var n := 0
		for f in fighters:
			if f.team == team:
				sum += f.health_ratio()
				n += 1
		var r := sum / n
		if best >= 0 and is_equal_approx(r, best_ratio):
			tie = true
		elif r > best_ratio:
			best = team
			best_ratio = r
			tie = false
	return -1 if tie else best


## Lowest slot on `team` (-1 for team -1 or an empty team).
func team_lead_slot(team: int) -> int:
	var lead := -1
	for f in fighters:
		if f.team == team and (lead < 0 or f.slot < lead):
			lead = f.slot
	return lead


## Rounds won by the team of the fighter in `slot`.
func wins_for_slot(slot: int) -> int:
	var f := fighter_for_slot(slot)
	if f == null or f.team >= wins.size():
		return 0
	return wins[f.team]


## Round start transform of fighters[i]: teams on opposite sides of the ring
## (more than two teams: evenly around it), spawn_distance apart across the
## centre, teammates side by side spawn_team_spacing apart, facing inward.
func spawn_transform(i: int) -> Transform3D:
	var f := fighters[i]
	var teams := _teams()
	var ti := teams.find(f.team)
	var mates: Array[Fighter] = []
	for o in fighters:
		if o.team == f.team:
			mates.append(o)
	var mi := mates.find(f)
	var radial := Vector3.BACK
	if teams.size() == 2:
		radial = Vector3.BACK if ti == 0 else Vector3.FORWARD
	elif teams.size() > 2:
		var a := TAU * ti / teams.size()
		radial = Vector3(sin(a), 0.0, cos(a))
	var side := Vector3(-radial.z, 0.0, radial.x)
	var r := Tuning.match_rules
	var pos := radial * (r.spawn_distance * 0.5) + side * ((mi - (mates.size() - 1) * 0.5) * r.spawn_team_spacing)
	return Transform3D(Basis.looking_at(-radial), pos)


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
