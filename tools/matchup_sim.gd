extends Node
## Roster balance: CPU vs CPU matches for every character pairing, at the same
## CPU level, swapping sides each match. Prints who beats whom (rounds won,
## row vs column) and a `MATCHUP <a> <b> <a's round win %>` line per pairing.
## The CPU doesn't play any character to its strengths on purpose, so this
## catches a broken pairing; it doesn't replace playing them.
##   godot --headless res://tools/matchup_sim.tscn -- runs=20 levels=3,5,7 [seed=1 only=titan]

var _args := {"runs": "20", "levels": "3,5,7", "seed": "1", "only": ""}


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		var kv := a.split("=")
		if kv.size() == 2 and _args.has(kv[0]):
			_args[kv[0]] = kv[1]
	print("matchup_sim ", _args)
	var ids := CharacterRegistry.ids()
	var levels: Array[int] = []
	for l in String(_args["levels"]).split(","):
		levels.append(int(l))
	var worst := 0.0
	for li in levels:
		print("--- CPU level %d: %% of decided rounds won, row vs column" % li)
		var rows: PackedStringArray = ["%8s" % ""]
		for id in ids:
			rows.append("%8s" % id)
		print(" ".join(rows))
		var table := {}
		for i in ids.size():
			for j in range(i, ids.size()):
				if _args["only"] != "" and _args["only"] != String(ids[i]) and _args["only"] != String(ids[j]):
					continue
				var r := _pairing(ids[i], ids[j], li)
				table[[i, j]] = r
				table[[j, i]] = {"pct": 100.0 - r["pct"], "secs": r["secs"]}
				print("MATCHUP L%d %s %s %.1f (%d rounds, %.1fs/round, %d timeouts)" % [
					li, ids[i], ids[j], r["pct"], r["rounds"], r["secs"], r["timeouts"]])
				if i != j:
					worst = maxf(worst, absf(r["pct"] - 50.0))
		for i in ids.size():
			var cells: PackedStringArray = ["%8s" % ids[i]]
			var sum := 0.0
			for j in ids.size():
				if table.has([i, j]):
					cells.append("%7.0f%%" % table[[i, j]]["pct"])
					sum += table[[i, j]]["pct"]
				else:
					cells.append("%8s" % "-")
			print(" ".join(cells), "   mean %.0f%%" % (sum / ids.size()))
	print("MATCHUP_WORST %.1f (furthest pairing from 50%%)" % (50.0 + worst))
	get_tree().quit(0)


func _pairing(a: StringName, b: StringName, level: int) -> Dictionary:
	var wins_a := 0
	var decided := 0
	var frames := 0
	var timeouts := 0
	for i in int(_args["runs"]):
		var swapped := i % 2 == 1
		var r := _match(b if swapped else a, a if swapped else b, level, int(_args["seed"]) * 1000 + i)
		wins_a += r["wins"][1 if swapped else 0]
		decided += r["wins"][0] + r["wins"][1]
		frames += r["ticks"]
		timeouts += r["timeouts"]
	var rounds := maxi(decided, 1)
	return {"pct": 100.0 * wins_a / rounds, "rounds": decided, "secs": frames / 60.0 / rounds, "timeouts": timeouts}


func _match(a: StringName, b: StringName, level: int, seed_value: int) -> Dictionary:
	var cfg := MatchConfig.from_defaults(MatchConfig.Mode.VERSUS_CPU)
	cfg.rng_seed = seed_value
	for i in 2:
		var p := PlayerSlotConfig.new()
		p.slot = i
		p.character_id = a if i == 0 else b
		p.input_kind = PlayerSlotConfig.InputKind.CPU
		p.cpu_level = level
		cfg.players.append(p)
	var d := MatchDirector.new()
	d.auto_step = false
	add_child(d)
	var timeouts := [0]
	d.round_ended.connect(func(_w: int, reason: StringName) -> void:
		if reason != &"ko":
			timeouts[0] += 1)
	d.setup(cfg)
	var cap := Tuning.match_rules.tick_rate * 900
	while d.tick < cap and d.phase != MatchDirector.Phase.MATCH_OVER:
		d.step()
	var out := {"wins": [d.wins[0], d.wins[1]], "ticks": d.tick, "timeouts": timeouts[0]}
	remove_child(d)
	d.free()
	return out
