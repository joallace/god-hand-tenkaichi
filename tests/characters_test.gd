extends Node
## The roster: generated data stays self-consistent for every character, and
## the per-character mechanics work (armor, knockback weight, mixed body
## sizes). Run as a scene:  godot --headless res://tests/characters_test.tscn

const B := InputFrame.Btn

var _failures := 0


func _ready() -> void:
	var tests: Array[Callable] = [
		_test_identity, _test_references, _test_derived_scaling, _test_string_links, _test_hit_heights,
		_test_low_profile_kept, _test_armor_absorbs_light, _test_armor_limits, _test_armor_save_load,
		_test_armor_scope, _test_getup_invuln, _test_charge_before_swing, _test_body_pass_order,
		_test_knockback_weight, _test_throw_hold_distance, _test_every_pairing_plays,
	]
	for t in tests:
		t.call()
	print("CHARACTER TESTS: %s (%d failures)" % ["PASS" if _failures == 0 else "FAIL", _failures])
	get_tree().quit(0 if _failures == 0 else 1)


func _check(cond: bool, label: String) -> bool:
	if not cond:
		print("FAIL %s" % label)
		_failures += 1
	else:
		print("PASS %s" % label)
	return cond


func _defs() -> Array[CharacterDef]:
	var out: Array[CharacterDef] = []
	for id in CharacterRegistry.ids():
		out.append(CharacterRegistry.load_def(id))
	return out


func _tuning(d: CharacterDef) -> FighterTuning:
	return d.build_tuning(Tuning.fighter)


func _test_identity() -> void:
	_check(CharacterRegistry.ids().size() == 4, "four characters")
	var titan := CharacterRegistry.load_def(&"titan")
	var bulk := CharacterRegistry.load_def(&"bulk")
	var sprite := CharacterRegistry.load_def(&"sprite")
	var brawler := CharacterRegistry.load_def(&"brawler")
	var dmg := func(d: CharacterDef) -> float: return d.move(d.light_string[0]).damage
	var startup := func(d: CharacterDef) -> int: return d.move(d.heavy).startup
	_check(_tuning(titan).body_height > _tuning(brawler).body_height, "titan is taller")
	_check(dmg.call(titan) > dmg.call(brawler) and startup.call(titan) > startup.call(brawler),
		"titan hits harder and slower")
	_check(_tuning(bulk).body_radius > _tuning(titan).body_radius, "bulk is the widest")
	_check(_tuning(bulk).max_health > _tuning(titan).max_health, "bulk has the most health")
	_check(_tuning(sprite).body_height < _tuning(brawler).body_height, "sprite is smaller")
	_check(_tuning(sprite).walk_speed > _tuning(brawler).walk_speed and startup.call(sprite) < startup.call(brawler),
		"sprite moves and attacks faster")
	_check(_tuning(sprite).max_health < _tuning(brawler).max_health, "sprite is less tanky")
	for d in _defs():
		var t := _tuning(d)
		for key: Variant in d.stat_overrides:
			_check(key in t, "%s: %s is a FighterTuning property" % [d.id, key])


## Every role and cross reference of a character stays inside its own moveset.
func _test_references() -> void:
	const ROLES := ["heavy", "heavy_high", "heavy_low", "finisher", "jump_attack", "jump_heavy", "duck_heavy",
		"getup_attack", "dash_attack", "ki_blast", "throw", "counter", "super1", "super2", "ultimate"]
	for d in _defs():
		var bad: Array[String] = []
		var prefix := String(d.id) + "_"
		var refs: Array[StringName] = []
		refs.append_array(d.light_string)
		for r: String in ROLES:
			refs.append(d.get(r))
		for m in d.moves:
			refs.append_array(m.cancel_into)
			refs.append_array(m.smash_variants)
			if m.charge_move != &"":
				refs.append(m.charge_move)
			if m.auto_next_on_hit != &"":
				refs.append(m.auto_next_on_hit)
			if m.spawn_move != null and not String(m.spawn_move.id).begins_with(prefix):
				bad.append(m.spawn_move.id)
		for r in refs:
			if d.move(r) == null:
				bad.append(r)
		_check(bad.is_empty(), "%s: references resolve in its own moveset %s" % [d.id, bad])


func _test_derived_scaling() -> void:
	var base := CharacterRegistry.load_def(&"brawler")
	for d in _defs():
		_check(d.moves.size() == base.moves.size(), "%s: full moveset" % d.id)
		for m in d.moves:
			if m.cancel_end > 0 and m.cancel_start <= m.startup:
				_check(false, "%s cancels before it hits" % m.id)
			if m.is_charge_strike() and m.charge_frame >= m.startup:
				_check(false, "%s charges after its startup" % m.id)
			if m.spawn_kind != &"" and m.spawn_frame != m.startup:
				_check(false, "%s spawns off its startup" % m.id)


## Each LIGHT string step still combos: the next hit lands inside the hitstun.
func _test_string_links() -> void:
	for d in _defs():
		for i in d.light_string.size() - 1:
			var a := d.move(d.light_string[i])
			var b := d.move(d.light_string[i + 1])
			var gap := a.cancel_start - a.startup + b.startup
			_check(gap < a.hitstun, "%s: %s links into %s (%d < %d)" % [d.id, a.id, b.id, gap, a.hitstun])


## Standing fighters of every size get hit by every string move and by highs;
## attack heights keep working against ducks for every attacker.
func _test_hit_heights() -> void:
	for a in _defs():
		var moves: Array[StringName] = a.light_string.duplicate()
		moves.append(a.heavy)
		moves.append(a.heavy_high)
		moves.append(a.heavy_low)
		for v in _defs():
			var t := _tuning(v)
			var top := maxf(t.body_height, t.body_radius * 2.0)
			for id in moves:
				var m := a.move(id)
				_check(m.hitbox_offset.y - m.hitbox_radius < top - 0.1, "%s reaches standing %s" % [id, v.id])


func _test_low_profile_kept() -> void:
	for a in _defs():
		var m := a.move(a.heavy_high)
		_check(m.hitbox_offset.y - m.hitbox_radius > Tuning.fighter.duck_height, "%s whiffs over a duck" % m.id)


func _match(p1: StringName, p2: StringName) -> MatchDirector:
	var cfg := MatchConfig.from_defaults(MatchConfig.Mode.VERSUS_CPU)
	for i in 2:
		var p := PlayerSlotConfig.new()
		p.slot = i
		p.character_id = p1 if i == 0 else p2
		p.input_kind = PlayerSlotConfig.InputKind.CPU
		p.cpu_level = 0
		cfg.players.append(p)
	var d := MatchDirector.new()
	d.auto_step = false
	d.source_factory = func(_cfg: PlayerSlotConfig) -> InputSource: return ScriptedInput.new()
	add_child(d)
	d.setup(cfg)
	while d.phase != MatchDirector.Phase.FIGHT:
		d.step()
	return d


func _end(d: MatchDirector) -> void:
	remove_child(d)
	d.free()


func _hitbox(attacker: Fighter, move: MoveData) -> Hitbox:
	var hb := Hitbox.new()
	hb.source = attacker
	hb.attacker = attacker
	hb.move = move
	hb.hit_id = 999
	hb.forward = Vector3.FORWARD
	hb.right = Vector3.RIGHT
	hb.origin = attacker.global_position
	hb.a = attacker.global_position
	hb.b = hb.a
	return hb


## Puts Bulk (slot 0) in the startup of its heavy.
func _start_bulk_heavy(d: MatchDirector) -> Fighter:
	var f := d.fighters[0]
	f._start_move(f.def.move(f.def.heavy))
	return f


func _test_armor_absorbs_light() -> void:
	var d := _match(&"bulk", &"brawler")
	var bulk := _start_bulk_heavy(d)
	var hp := bulk.health
	var jab: MoveData = d.fighters[1].def.move(&"brawler_jab1")
	var c := bulk.receive_hit(_hitbox(d.fighters[1], jab))
	_check(c == CombatEntity.Contact.BLOCKED, "armor reports the jab like a block")
	_check(bulk.current_state_name() == &"attack", "armor keeps the heavy going")
	_check(is_equal_approx(bulk.health, hp - jab.damage * bulk.tuning.armor_damage_ratio), "armor halves the damage")
	var c2 := bulk.receive_hit(_hitbox(d.fighters[1], jab))
	_check(c2 == CombatEntity.Contact.HIT and bulk.current_state_name() == &"hitstun",
		"a second light in the same move interrupts")
	_end(d)


func _test_armor_limits() -> void:
	var d := _match(&"bulk", &"brawler")
	var bulk := _start_bulk_heavy(d)
	var heavy: MoveData = d.fighters[1].def.move(&"brawler_kick_mid")
	_check(bulk.receive_hit(_hitbox(d.fighters[1], heavy)) == CombatEntity.Contact.HIT, "a heavy beats armor")
	_end(d)
	d = _match(&"bulk", &"brawler")
	bulk = d.fighters[0]
	var jab: MoveData = d.fighters[1].def.move(&"brawler_jab1")
	bulk._start_move(bulk.def.move(bulk.def.light_string[0]))
	_check(bulk.receive_hit(_hitbox(d.fighters[1], jab)) == CombatEntity.Contact.HIT, "lights have no armor")
	_end(d)
	d = _match(&"bulk", &"brawler")
	bulk = _start_bulk_heavy(d)
	var m: MoveData = bulk.current_move()
	for i in m.startup + m.active + 1:
		d.step()
	_check(bulk.attack_phase() == 2, "reached recovery")
	_check(bulk.receive_hit(_hitbox(d.fighters[1], jab)) == CombatEntity.Contact.HIT, "recovery has no armor")
	_end(d)


## Paid supers and throws beat armor; Bulk's own throw has none to spend.
func _test_armor_scope() -> void:
	var d := _match(&"bulk", &"brawler")
	var bulk := _start_bulk_heavy(d)
	var rush: MoveData = d.fighters[1].def.move(&"brawler_rush")
	_check(bulk.receive_hit(_hitbox(d.fighters[1], rush)) == CombatEntity.Contact.HIT, "a rush super beats armor")
	_end(d)
	var def := CharacterRegistry.load_def(&"bulk")
	_check(def.move(def.throw).armor_hits == 0, "bulk's throw has no armor")
	_check(def.move(def.heavy).armor_hits == 1, "bulk's heavy has armor")
	_check(def.move(def.super1).armor_hits == 0, "bulk's rush has no armor")


func _test_getup_invuln() -> void:
	for d in _defs():
		var m := d.move(d.getup_attack)
		_check(_tuning(d).getup_attack_invuln_frames >= m.startup + m.active, "%s: spin is invulnerable" % d.id)


## Holding HEAVY converts to the charge strike before the plain swing hits.
func _test_charge_before_swing() -> void:
	for d in _defs():
		var t := _tuning(d)
		for id in [d.heavy, d.heavy_high, d.heavy_low]:
			_check(t.charge_hold_frames <= d.move(id).startup, "%s: charge converts before the hit" % id)


## Who passes over whom doesn't depend on the slot order.
func _test_body_pass_order() -> void:
	var run := func(p1: StringName, p2: StringName, high: int) -> float:
		var d := _match(p1, p2)
		var a := d.fighters[0]
		var b := d.fighters[1]
		a.global_position = Vector3.ZERO
		b.global_position = Vector3(0.1, 0, 0)
		d.fighters[high].global_position.y = 1.6  # above Sprite's 1.45, under Brawler's 1.8
		d.combat._separate_fighters()
		var dist := Vector2(a.global_position.x - b.global_position.x, a.global_position.z - b.global_position.z).length()
		_end(d)
		return dist
	_check(is_equal_approx(run.call(&"sprite", &"brawler", 1), run.call(&"brawler", &"sprite", 0)),
		"body separation is side independent")


func _test_armor_save_load() -> void:
	var d := _match(&"bulk", &"brawler")
	var bulk := _start_bulk_heavy(d)
	var jab: MoveData = d.fighters[1].def.move(&"brawler_jab1")
	var s := d.save_state()
	bulk.receive_hit(_hitbox(d.fighters[1], jab))
	var spent := StateHash.of(d)
	d.load_state(s)
	_check(StateHash.of(d) == StateHash.of_state(s), "save/load round trip with armor")
	bulk = d.fighters[0]
	_check(bulk.receive_hit(_hitbox(d.fighters[1], jab)) == CombatEntity.Contact.BLOCKED, "rollback restores armor")
	_check(StateHash.of(d) == spent, "resim matches")
	_end(d)


func _test_knockback_weight() -> void:
	var launch := func(id: StringName) -> float:
		var d := _match(id, &"brawler")
		var f := d.fighters[0]
		var m: MoveData = d.fighters[1].def.move(&"brawler_smash_up")
		f.receive_hit(_hitbox(d.fighters[1], m))
		var y := f._vel.y
		_end(d)
		return y
	var base: float = launch.call(&"brawler")
	_check(launch.call(&"bulk") < base, "bulk launches lower")
	_check(launch.call(&"sprite") > base, "sprite launches higher")


func _test_throw_hold_distance() -> void:
	var d := _match(&"bulk", &"bulk")
	var a := d.fighters[0]
	_check(a._throw_hold_distance(d.fighters[1]) >= a.tuning.body_radius * 2.0, "wide bodies held apart")
	_end(d)
	d = _match(&"brawler", &"brawler")
	_check(is_equal_approx(d.fighters[0]._throw_hold_distance(d.fighters[1]), Tuning.fighter.throw_hold_distance),
		"default hold distance unchanged")
	_end(d)


## Real CPU fights for every pairing run through with a stable state hash.
func _test_every_pairing_plays() -> void:
	var ids := CharacterRegistry.ids()
	for a in ids:
		for b in ids:
			var runs: Array[int] = []
			for i in 2:
				var cfg := MatchConfig.from_defaults(MatchConfig.Mode.VERSUS_CPU)
				cfg.rng_seed = 42
				for s in 2:
					var p := PlayerSlotConfig.new()
					p.slot = s
					p.character_id = a if s == 0 else b
					p.input_kind = PlayerSlotConfig.InputKind.CPU
					p.cpu_level = 5
					cfg.players.append(p)
				var d := MatchDirector.new()
				d.auto_step = false
				add_child(d)
				d.setup(cfg)
				for t in 900:
					d.step()
				runs.append(StateHash.of(d))
				_end(d)
			_check(runs[0] == runs[1], "%s vs %s is deterministic" % [a, b])
