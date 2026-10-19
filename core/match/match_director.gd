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
## Teams: every fighter has a team (PlayerSlotConfig.team, default = slot, so
## 1v1 is two teams of one). A round ends when at most one team has a fighter
## standing; on time-out the team with the best mean health ratio wins.
## `wins` is indexed by TEAM; round_ended/match_ended still carry a winner
## slot (the lowest slot of the winning team, -1 = draw) and
## `last_winner_team` holds the team. The director sets each fighter's
## `target` at round start / spawn (pick_default_target) and replaces KO'd
## ones (_update_targets); manual locks and periodic re-picks are the
## fighter's own targeting (see Fighter header). Both use Targeting.
##
## Co-op (Mode.COOP): one run, no rounds (INTRO -> FIGHT -> MATCH_OVER).
## config.players are team 0 and `downable`; CoopRun (`coop`) spawns the
## team-1 enemies, refills the field, removes KO'd enemies and decides the
## end (run_ended); round_time_seconds limits the whole run (time-out = loss).
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
## A sim entity (fighter or projectile) joined / is about to leave the match:
## spawned, freed, or rebuilt / dropped by load_state. Fighters created by
## setup() are announced by fighters_spawned instead.
signal entity_spawned(e: SimEntity)
signal entity_removed(e: SimEntity)
## Co-op: the run is over (cleared = every enemy beaten). match_ended follows
## with team 0's lead slot when cleared, -1 otherwise.
signal run_ended(cleared: bool)
## Co-op: enemies still to beat (queued + standing) changed.
signal enemies_left_changed(left: int)
## Co-op Waves: wave `wave` (0-based) starts entering / was fully beaten
## (the breather follows unless it was the last one; then run_ended).
signal wave_started(wave: int)
signal wave_cleared(wave: int)

enum Phase { NONE, INTRO, FIGHT, OUTRO, MATCH_OVER }

var config: MatchConfig
var fighters: Array[Fighter] = []
var entities: Array[SimEntity] = []  # non-fighter entities (projectiles...)
var combat: CombatSystem
## Co-op attack tokens / grab lock (always present; disabled outside COOP).
var encounter: EncounterDirector
## Play radius (m): fighters are clamped inside it. Fixed for the match.
var arena_radius: float = 0.0
## Co-op run flow (null outside Mode.COOP).
var coop: CoopRun
var sources: Array[InputSource] = []

var tick: int = 0
var phase: Phase = Phase.NONE
var phase_frames: int = 0
var round_number: int = 0
var round_frames_left: int = 0
## Rounds won, indexed by team id.
var wins: PackedInt32Array = PackedInt32Array()
## Frames the whole sim stays frozen (ultimate, counter guard, push-stop).
var world_freeze: int = 0
## Next SimEntity.sim_id. Ids are never reused within a match, so snapshots
## name entities unambiguously; fighters, then entities, tick in id order.
var next_sim_id: int = 1
## Team that won the last round (-1 = draw / none yet).
var last_winner_team: int = -1
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
## True while a rollback re-simulates ticks already shown (set by the online
## driver around its catch-up steps). Presentation reads it to mute repeats.
var resimulating := false

var _last_second_emitted := -2


func setup(p_config: MatchConfig) -> void:
	config = p_config
	combat = CombatSystem.new(self)
	encounter = EncounterDirector.new(self)
	arena_radius = arena_radius_for(config)
	if is_coop():
		coop = CoopRun.new(self)
	var max_team := CoopRun.ENEMY_TEAM if is_coop() else 0
	for p in config.players:
		max_team = maxi(max_team, _config_team(p))
	wins.resize(max_team + 1)
	wins.fill(0)
	for p in config.players:
		var src := p.create_input_source()
		src.attach(self, p.slot)
		sources.append(src)
		var f := EntityFactory.create_fighter(p.slot, p.character_id, _config_team(p))
		f.sim_id = _take_sim_id()
		_apply_mode_flags(f)
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

	if world_freeze > 0:
		world_freeze -= 1
	else:
		for f in fighters:
			_tick_entity(f)
		for e in entities.duplicate():
			_tick_entity(e)
		combat.resolve(tick)
		encounter.sim_tick(tick)
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
	if coop != null:
		coop.tick_fight()
		if phase == Phase.FIGHT and not config.is_infinite_time() and round_frames_left <= 0:
			_end_run(false)
		if phase == Phase.FIGHT:
			_update_targets()
		return
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
	world_freeze = 0
	for e in entities:
		_free_node(e)
	entities.clear()
	round_frames_left = config.round_time_seconds * Tuning.match_rules.tick_rate
	for i in fighters.size():
		fighters[i].reset_for_round(spawn_transform(i))
		fighters[i].set_control_enabled(false)
	for f in fighters:
		f.target = pick_default_target(f)
	for s in sources:
		s.reset()
	if coop != null:
		coop.start()
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


## Co-op run over (CoopRun or time-out): no OUTRO, straight to MATCH_OVER.
func _end_run(cleared: bool) -> void:
	for f in fighters:
		f.set_control_enabled(false)
	last_winner_team = CoopRun.HUMAN_TEAM if cleared else CoopRun.ENEMY_TEAM
	wins[last_winner_team] += 1
	_set_phase(Phase.MATCH_OVER)
	run_ended.emit(cleared)
	match_ended.emit(team_lead_slot(CoopRun.HUMAN_TEAM) if cleared else -1)


func is_coop() -> bool:
	return config != null and config.mode == MatchConfig.Mode.COOP


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


# --- Teams ---------------------------------------------------------------------

## Play radius for a match: co-op grows it by arena_radius_per_extra_fighter
## for every fighter the run can field beyond two.
static func arena_radius_for(cfg: MatchConfig) -> float:
	var r := Tuning.match_rules.arena_radius
	if cfg != null and cfg.mode == MatchConfig.Mode.COOP:
		r += Tuning.coop.arena_radius_per_extra_fighter * maxi(CoopRun.planned_field_size(cfg) - 2, 0)
	return r


## Default target for `f`: what its own auto policy (Fighter.best_target,
## Targeting.pick_auto) picks from scratch, or null if no enemy is
## targetable. Used at round start and spawn; one place to swap the policy.
func pick_default_target(f: Fighter) -> Fighter:
	return f.best_target()


## Re-pick (Fighter.retarget_auto, which also drops a manual lock) for every
## standing fighter whose target is gone, KO'd or a teammate; keeps the old
## one when no enemy is targetable (e.g. the round is ending). Everything
## else (manual locks, periodic re-picks) is the fighter's own targeting.
func _update_targets() -> void:
	for f in fighters:
		if f.is_ko() or (f.target != null and not f.target.is_ko() and f.target.team != f.team):
			continue
		f.retarget_auto()


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
## Co-op: team 0 stands around the centre (CoopRun.human_transform).
func spawn_transform(i: int) -> Transform3D:
	var f := fighters[i]
	var teams := _teams()
	var ti := teams.find(f.team)
	var mates: Array[Fighter] = []
	for o in fighters:
		if o.team == f.team:
			mates.append(o)
	var mi := mates.find(f)
	if coop != null and f.team == CoopRun.HUMAN_TEAM:
		return CoopRun.human_transform(mi, mates.size())
	var radial := Vector3.BACK
	if teams.size() == 2:
		radial = Vector3.BACK if ti == 0 else Vector3.FORWARD
	elif teams.size() > 2:
		var a := TAU * ti / teams.size()
		radial = Vector3(DetMath.sin(a), 0.0, DetMath.cos(a))
	var side := Vector3(-radial.z, 0.0, radial.x)
	var r := Tuning.match_rules
	var pos := radial * (r.spawn_distance * 0.5) + side * ((mi - (mates.size() - 1) * 0.5) * r.spawn_team_spacing)
	return Transform3D(DetMath.looking_at(-radial), pos)


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
	_apply_mode_flags(f)
	if f.team >= wins.size():
		wins.resize(f.team + 1)  # new entries are 0
	_add_fighter(f, _source_for(f))
	f.set_control_enabled(phase == Phase.FIGHT)
	f.target = pick_default_target(f)
	_update_targets()
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
		if f.target != null and not fighters.has(f.target):
			f.target = null
	for src in sources:
		var cpu := src as CpuInput
		if cpu != null and cpu.brain.opp != null and not fighters.has(cpu.brain.opp):
			cpu.brain.opp = null  # the brain re-binds to its fighter's new target
	_update_targets()


func _take_sim_id() -> int:
	next_sim_id += 1
	return next_sim_id - 1


## Co-op forces every config player onto team 0.
func _config_team(p: PlayerSlotConfig) -> int:
	if is_coop():
		return CoopRun.HUMAN_TEAM
	return p.team if p.team >= 0 else p.slot


## Mode-derived fighter flags (not saved; reapplied to rebuilt fighters).
func _apply_mode_flags(f: Fighter) -> void:
	f.downable = coop != null and f.team == CoopRun.HUMAN_TEAM


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
		"encounter": encounter.save_state(),
		"coop": coop.save_state() if coop != null else {},
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
	encounter.load_state(s["encounter"])
	if coop != null:
		coop.load_state(s["coop"])
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
		_apply_mode_flags(f)
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
