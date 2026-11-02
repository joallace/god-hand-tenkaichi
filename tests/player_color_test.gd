extends Node
## Player colours: the lobby's Colour row and its rules, the wire / replay
## form, and what the fighters end up wearing: picks in versus, one enemy
## colour outside the palette in co-op, surviving a rollback that recreates
## a fighter, and invisible to the sim (same state hash whatever the colour).
##   godot --headless res://tests/player_color_test.tscn

const FRAMES := 30

var _failures := 0


func _ready() -> void:
	_test_lobby_rules()
	_test_wire()
	_test_versus_colors()
	_test_coop_colors()
	_test_rollback_keeps_colors()
	_test_hash_ignores_color()
	print("player_color_test: %s" % ("FAILED (%d)" % _failures if _failures > 0 else "PASS"))
	get_tree().quit(1 if _failures > 0 else 0)


func _check(ok: bool, what: String) -> void:
	if not ok:
		_failures += 1
		printerr("FAIL: ", what)


func _join(m: LobbyModel, count: int) -> void:
	for i in count:
		m.join(Bindings.Kind.PAD, i)


func _pick(m: LobbyModel, idx: int, dir: int) -> void:
	m.slots[idx].cursor = LobbyModel.Row.COLOR
	m.command(idx, LobbyModel.Cmd.RIGHT if dir > 0 else LobbyModel.Cmd.LEFT)


func _test_lobby_rules() -> void:
	var m := LobbyModel.new(MatchConfig.Mode.LOCAL_VERSUS)
	_join(m, 2)
	_check(m.resolved_colors()[0] == 0 and m.resolved_colors()[1] == 1, "slots default to their own colour")
	_check(LobbyModel.Row.COLOR in m.rows_for(0), "players have a Colour row")

	_pick(m, 0, 1)
	_check(m.slots[0].color_index == 1, "P1 takes P2's default")
	var colors := m.resolved_colors()
	_check(colors[0] == 1 and colors[1] != 1, "the unpicked P2 moves out of the way")

	_pick(m, 1, 1)  # P2 picks too; now both are real picks
	var theirs := m.slots[1].color_index
	m.slots[0].cursor = LobbyModel.Row.COLOR
	for i in Tuning.colors.count() * 2:
		m.command(0, LobbyModel.Cmd.RIGHT)
		_check(m.slots[0].color_index != theirs, "cycling skips a colour someone picked")

	m.slots[0].color_index = 3
	m.slots[1].color_index = 7
	_pick(m, 0, -1)
	_check(m.slots[0].color_index == 2, "left steps back")
	m.leave(1)
	_check(m.slots[1].color_index == -1, "leaving frees the colour")

	m.slots[1].color_index = 2  # remembered, nobody there: free to take
	m.slots[0].color_index = 1
	_pick(m, 0, 1)
	_check(m.slots[0].color_index == 2 and m.slots[1].color_index == -1, "a pick on an empty slot reserves nothing")

	var online := LobbyModel.new(MatchConfig.Mode.ONLINE, true)
	online.slots[1].state = LobbyModel.SlotState.JOINED
	online.slots[1].owner_peer = 2
	_check(LobbyModel.Row.COLOR in online.rows_for(1), "online guests can pick a colour")
	online.slots[0].state = LobbyModel.SlotState.READY
	online.slots[0].owner_peer = 1
	_pick(online, 1, 1)
	_check(online.slots[0].state == LobbyModel.SlotState.READY, "a colour isn't a rule: nobody is un-readied")


func _test_wire() -> void:
	var m := LobbyModel.new(MatchConfig.Mode.ONLINE, true)
	m.slots[0].color_index = 5
	var mirror := LobbyModel.new(MatchConfig.Mode.ONLINE, true)
	_check(mirror.apply_dict(m.to_dict()) and mirror.slots[0].color_index == 5, "lobby state carries the colour")

	var p := PlayerSlotConfig.new()
	p.color_index = 5
	var back := PlayerSlotConfig.from_dict(p.to_dict())
	_check(back != null and back.color_index == 5, "slot config round trip")
	var d := p.to_dict()
	d.erase("color_index")
	_check(PlayerSlotConfig.from_dict(d).color_index == -1, "older data: slot default")
	d["color_index"] = 9999
	_check(PlayerSlotConfig.from_dict(d).color_index == Tuning.colors.count() - 1, "hostile index is clamped")


func _test_versus_colors() -> void:
	var m := LobbyModel.new(MatchConfig.Mode.LOCAL_VERSUS)
	_join(m, 2)
	m.slots[0].color_index = 4
	var cfg := m.build_config(1)
	_check(cfg.color_of(0) == Tuning.colors.color(4), "the config has the pick")
	_check(cfg.color_of(1) == Tuning.colors.color(1), "and the other player's default")


func _test_coop_colors() -> void:
	var m := LobbyModel.new(MatchConfig.Mode.COOP)
	_join(m, 1)
	m.slots[0].color_index = 2
	m.coop_ally = true
	var cfg := m.build_config(1)
	_check(cfg.players[1].color_index != 2, "the CPU ally doesn't copy the player")
	_check(not Tuning.colors.enemy_color in Tuning.colors.palette, "no player can wear the enemy colour")
	_check(cfg.color_of(cfg.players.size()) == Tuning.colors.enemy_color, "slots past the players are enemies")
	_check(Tuning.colors.names.size() == Tuning.colors.count(), "every palette colour has a name")


func _director(cfg: MatchConfig) -> MatchDirector:
	var d := MatchDirector.new()
	d.auto_step = false
	add_child(d)
	d.setup(cfg)
	return d


func _coop_config() -> MatchConfig:
	var m := LobbyModel.new(MatchConfig.Mode.COOP)
	_join(m, 1)
	m.slots[0].color_index = 2
	var cfg := m.build_config(11)
	cfg.players[0].input_kind = PlayerSlotConfig.InputKind.CPU
	cfg.players[0].cpu_level = 0
	return cfg


func _test_rollback_keeps_colors() -> void:
	var d := _director(_coop_config())
	for i in FRAMES:
		d.step()
	_check(d.fighters.size() > 1, "enemies spawned")
	_check(d.fighters[0].tint() == Tuning.colors.color(2), "the player wears the pick")
	var enemy: Fighter = d.fighters[d.fighters.size() - 1]
	_check(enemy.tint() == Tuning.colors.enemy_color, "enemies wear the enemy colour")
	var snapshot := d.save_state()
	var enemy_slot := enemy.slot
	d.remove_fighter(enemy)
	d.load_state(snapshot)
	var back := d.fighter_for_slot(enemy_slot)
	_check(back != null and back != enemy and back.tint() == Tuning.colors.enemy_color,
			"a fighter recreated by load_state keeps its colour")
	d.queue_free()


func _versus_hash(color: int) -> int:
	var cfg := MatchConfig.from_defaults(MatchConfig.Mode.LOCAL_VERSUS)
	cfg.rng_seed = 5
	for i in 2:
		var p := PlayerSlotConfig.new()
		p.slot = i
		p.input_kind = PlayerSlotConfig.InputKind.CPU
		p.cpu_level = 0
		p.color_index = color
		cfg.players.append(p)
	var d := _director(cfg)
	for i in FRAMES:
		d.step()
	var h := StateHash.of(d)
	d.queue_free()
	return h


func _test_hash_ignores_color() -> void:
	_check(_versus_hash(-1) == _versus_hash(6), "colours never reach the sim state")
