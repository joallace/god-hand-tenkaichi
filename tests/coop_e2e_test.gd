extends Node
## End-to-end co-op run: every milestone-3 system at once (CoopRun queue and
## refills, EncounterDirector tokens, CPU target choice, ENTERING, DOWNED /
## OUT). Two strong CPU players on team 0 against weak enemies, simulated
## until the run ends. Invariants are checked after every tick; a mid-run
## snapshot must re-simulate identically. Run as a scene:
##   godot --headless res://tests/coop_e2e_test.tscn

const ENEMIES := 6
## Sim ticks before giving up on the run ending (~6 min at 60 Hz).
const MAX_TICKS := 21600
## Ticks re-simulated from the snapshot for the determinism check.
const RESIM_TICKS := 600
## Tick (in FIGHT) at which the snapshot is taken.
const SNAPSHOT_AT := 1200

var _failures := 0
var _events := {}  # kind -> count
var _ended: Array = []  # run_ended cleared flags


func _ready() -> void:
	_test_full_run()
	_test_resim_mid_run()
	print("COOP E2E TESTS: %s (%d failures)" % ["PASS" if _failures == 0 else "FAIL", _failures])
	get_tree().quit(0 if _failures == 0 else 1)


func _check(cond: bool, label: String) -> bool:
	print("%s %s" % ["PASS" if cond else "FAIL", label])
	if not cond:
		_failures += 1
	return cond


func _new_run() -> MatchDirector:
	for c in get_children():
		c.queue_free()
	_events.clear()
	_ended.clear()
	var strongest := Tuning.cpu.level_names.size() - 1
	var cfg := MatchConfig.from_defaults(MatchConfig.Mode.COOP)
	cfg.round_time_seconds = 0
	cfg.rng_seed = 4321
	cfg.coop = CoopConfig.new()
	cfg.coop.enemy_count = ENEMIES
	cfg.coop.enemy_level = 0
	for i in 2:
		var p := PlayerSlotConfig.new()
		p.slot = i
		p.input_kind = PlayerSlotConfig.InputKind.CPU
		p.cpu_level = strongest
		cfg.players.append(p)
	var d := MatchDirector.new()
	d.auto_step = false
	add_child(d)
	d.run_ended.connect(func(c: bool) -> void: _ended.append(c))
	d.fighters_spawned.connect(func(fs: Array[Fighter]) -> void:
		for f in fs:
			_watch(f))
	d.entity_spawned.connect(func(e: SimEntity) -> void:
		if e is Fighter:
			_watch(e as Fighter))
	d.setup(cfg)
	return d


func _watch(f: Fighter) -> void:
	f.event.connect(func(kind: StringName, _data: Dictionary) -> void:
		_events[kind] = _events.get(kind, 0) + 1)


## Every tick: token caps per protected fighter, no enemy targeting a downed /
## out fighter while a targetable one is left (with none left, enemies keep
## their last target), entering enemies hold no tokens. Returns the first
## violation ("" = none).
func _violation(d: MatchDirector) -> String:
	var enc := d.encounter
	var any_targetable := false
	for f in d.fighters:
		if f.team == CoopRun.HUMAN_TEAM and f.is_targetable():
			any_targetable = true
	var melee_cap := Tuning.coop.melee_tokens_per_player
	var ranged_cap := Tuning.coop.ranged_tokens_per_player
	for f in d.fighters:
		if f.team == CoopRun.HUMAN_TEAM:
			var m := enc.holders(f, EncounterDirector.Kind.MELEE).size()
			var r := enc.holders(f, EncounterDirector.Kind.RANGED).size()
			if m > melee_cap or r > ranged_cap:
				return "tick %d: slot %d has %d melee / %d ranged token holders" % [d.tick, f.slot, m, r]
		else:
			if any_targetable and f.target != null and not f.is_ko() \
					and (f.target.is_downed() or f.target.is_out()):
				return "tick %d: enemy %d targets downed/out slot %d" % [d.tick, f.slot, f.target.slot]
			if f.is_entering() and (enc.holds_token(f, EncounterDirector.Kind.MELEE)
					or enc.holds_token(f, EncounterDirector.Kind.RANGED)):
				return "tick %d: entering enemy %d holds a token" % [d.tick, f.slot]
	return ""


func _test_full_run() -> void:
	var d := _new_run()
	var bad := ""
	var max_enemies_on_field := 0
	while _ended.is_empty() and d.tick < MAX_TICKS:
		d.step()
		if bad == "":
			bad = _violation(d)
		max_enemies_on_field = maxi(max_enemies_on_field, d.fighters.size() - 2)
	_check(bad == "", "invariants hold all run (%s)" % (bad if bad != "" else "ok"))
	_check(not _ended.is_empty(), "the run ends within %d ticks (ended at %d, cleared %s)" % [MAX_TICKS, d.tick, _ended])
	_check(max_enemies_on_field <= Tuning.coop.field_cap - 2, "field cap respected (max %d enemies at once)" % max_enemies_on_field)
	_check(_events.get(&"entry", 0) == ENEMIES, "every enemy entered once (%d)" % _events.get(&"entry", 0))
	_check(_events.get(&"ko", 0) >= (ENEMIES if _ended == [true] else 0), "enemy KOs counted (%d)" % _events.get(&"ko", 0))
	print("  events: %s" % _events)
	for f in d.fighters:
		print("  slot %d team %d %s hp %.0f/%.0f" % [f.slot, f.team, f.current_state_name(), f.health, f.tuning.max_health])


func _test_resim_mid_run() -> void:
	var d := _new_run()
	while d.phase != MatchDirector.Phase.FIGHT:
		d.step()
	for i in SNAPSHOT_AT:
		d.step()
	var snap := d.save_state()
	for i in RESIM_TICKS:
		d.step()
	var first := var_to_str(d.save_state())
	d.load_state(snap)
	for i in RESIM_TICKS:
		d.step()
	_check(var_to_str(d.save_state()) == first, "mid-run snapshot re-simulates identically (%d ticks)" % RESIM_TICKS)
