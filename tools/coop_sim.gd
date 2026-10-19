extends Node
## Headless co-op balance experiment: CPU-only Brawl runs (team 0 = CPU
## stand-ins for the players) with the experimental offscreen_attack_rule off
## and on, reporting clear rate, run length, hits taken by team 0 and the
## share of them that came from outside the victim's view cone
## (coop.offscreen_cone_half_angle). A scene, not --script, so autoloads exist:
##   godot --headless res://tools/coop_sim.tscn [-- runs=8 humans=1 enemies=4 level=3 enemy_level=3 seconds=120]
## Any `coop.<property>=<number>` argument overrides that Tuning.coop value
## for the session (e.g. coop.melee_tokens_per_player=1).

## Attacker state name -> hits landed on team 0 without a token on the victim.
var _untokened_states: Dictionary = {}
var _args := {"runs": 8, "humans": 1, "enemies": 4, "level": 3, "enemy_level": 3, "seconds": 120}


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		var kv := a.split("=")
		if kv.size() == 2 and _args.has(kv[0]):
			_args[kv[0]] = int(kv[1])
		elif kv.size() == 2 and kv[0].begins_with("coop."):
			var prop := kv[0].trim_prefix("coop.")
			var cur: Variant = Tuning.coop.get(prop)
			Tuning.coop.set(prop, float(kv[1]) if cur is float else int(kv[1]))
			print("override coop.%s = %s" % [prop, Tuning.coop.get(prop)])
	print("coop_sim ", _args)
	for rule in [false, true]:
		Tuning.coop.offscreen_attack_rule = rule
		_batch(rule)
	get_tree().quit(0)


func _batch(rule: bool) -> void:
	var cleared := 0
	var frames := 0
	var hits := 0
	var behind := 0
	var damage := 0.0
	var untokened := 0
	var dealt := 0.0
	var kos := 0
	_untokened_states.clear()
	for i in _args["runs"]:
		var r := _run(1000 + i)
		cleared += int(r["cleared"])
		frames += r["frames"]
		hits += r["hits"]
		behind += r["behind"]
		damage += r["damage"]
		untokened += r["untokened"]
		dealt += r["dealt"]
		kos += r["kos"]
	var n: int = _args["runs"]
	print("offscreen_rule=%s  cleared %d/%d  mean %.1fs  hits on team0 %.1f/run  dmg %.0f/run  from outside cone %.0f%%  without a token %.0f%%" % [
		rule, cleared, n, frames / 60.0 / n, hits / float(n), damage / n, 100.0 * behind / maxf(hits, 1),
		100.0 * untokened / maxf(hits, 1)])
	print("    team0 dealt %.0f dmg/run, %.2f enemy KOs/run; untokened hits by attacker state: %s" % [
		dealt / n, kos / float(n), _untokened_states])


func _run(seed_value: int) -> Dictionary:
	var cfg := MatchConfig.from_defaults(MatchConfig.Mode.COOP)
	cfg.round_time_seconds = _args["seconds"]
	cfg.rng_seed = seed_value
	cfg.coop = CoopConfig.new()
	cfg.coop.enemy_count = _args["enemies"]
	cfg.coop.enemy_level = _args["enemy_level"]
	for i in _args["humans"]:
		var p := PlayerSlotConfig.new()
		p.slot = i
		p.input_kind = PlayerSlotConfig.InputKind.CPU
		p.cpu_level = _args["level"]
		cfg.players.append(p)
	var d := MatchDirector.new()
	d.auto_step = false
	add_child(d)
	var out := {"cleared": false, "frames": 0, "hits": 0, "behind": 0, "damage": 0.0, "untokened": 0, "dealt": 0.0, "kos": 0}
	var watch := func(f: Fighter) -> void:
		f.event.connect(func(kind: StringName, data: Dictionary) -> void:
			if kind == &"hit" and f.team != CoopRun.HUMAN_TEAM:
				out["dealt"] += float(data.get("damage", 0.0))
			if kind == &"ko" and f.team != CoopRun.HUMAN_TEAM:
				out["kos"] += 1
			if kind != &"hit" or f.team != CoopRun.HUMAN_TEAM or data.get("blocked", false):
				return
			var att := d.fighter_for_slot(data.get("attacker_slot", -1))
			if att == null or att.team == f.team:
				return
			out["hits"] += 1
			out["damage"] += float(data.get("damage", 0.0))
			var to := att.global_position - f.global_position
			var fwd := -f.global_basis.z
			to.y = 0.0
			fwd.y = 0.0
			if to.length() > 0.01 and rad_to_deg(fwd.angle_to(to)) > Tuning.coop.offscreen_cone_half_angle:
				out["behind"] += 1
			var enc := d.encounter
			if not (att.slot in enc.holders(f, EncounterDirector.Kind.MELEE) or att.slot in enc.holders(f, EncounterDirector.Kind.RANGED)):
				out["untokened"] += 1
				var key := String(att.current_state_name())
				_untokened_states[key] = _untokened_states.get(key, 0) + 1)
	d.fighters_spawned.connect(func(fs: Array[Fighter]) -> void:
		for f in fs:
			watch.call(f))
	d.entity_spawned.connect(func(e: SimEntity) -> void:
		if e is Fighter:
			watch.call(e))
	d.run_ended.connect(func(c: bool) -> void: out["cleared"] = c)
	d.setup(cfg)
	var start := -1
	while d.phase != MatchDirector.Phase.MATCH_OVER and d.tick < (_args["seconds"] + 10) * 60:
		d.step()
		if start < 0 and d.phase == MatchDirector.Phase.FIGHT:
			start = d.tick
	out["frames"] = d.tick - maxi(start, 0)
	d.queue_free()
	return out
