extends SceneTree
## SOURCE OF TRUTH for character movesets. Writes data/moves/<id>.tres and
## data/characters/<id>.tres (always overwrites). Edit numbers here, rerun:
##   godot --headless --script res://tools/generate_moves.gd
##
## Units: frames (60/s), meters, m/s. Vectors in fighter space
## (x = right, y = up, z = forward / away from the attacker).

const MoveDataScript := preload("res://gameplay/combat/move_data.gd")
const CharacterDefScript := preload("res://gameplay/characters/character_def.gd")
const MOVES_DIR := "res://data/moves/"
const CHAR_DIR := "res://data/characters/"

const LIGHT := 1   # InputFrame.Btn.LIGHT
const HEAVY := 2   # InputFrame.Btn.HEAVY
const BLAST := 4   # InputFrame.Btn.BLAST
const HIGH := 1    # MoveData.Height.HIGH
const LOW := 2     # MoveData.Height.LOW


func _init() -> void:
	DirAccess.make_dir_recursive_absolute(MOVES_DIR)
	DirAccess.make_dir_recursive_absolute(CHAR_DIR)
	_save_char(_brawler())
	quit()


func _brawler() -> Resource:
	var moves: Array = []
	# --- LIGHT string: jab, jab, hook, kick; HEAVY after any = finisher ------
	# The finisher is directional: stick forward / neutral / back = high / mid /
	# low kick (Fighter picks by MoveData.height). Holding LIGHT charges.
	var finishers: Array = [&"brawler_finisher_high", &"brawler_finisher", &"brawler_finisher_low"]
	var light_common := {
		"button": LIGHT, "guard_stun": 10, "guard_damage": 4.0, "hitbox_radius": 0.45,
		"special_cancelable": true, "lunge_speed": 2.5, "lunge_frames": 6,
		"charge_move": &"brawler_charge_punch",
	}
	moves.append(_mk(light_common, {
		"id": &"brawler_jab1", "pose": &"jab", "startup": 5, "active": 3, "recovery": 12,
		"damage": 30.0, "hitstun": 20, "knockback": Vector3(0, 0, 1.5),
		"hitbox_offset": Vector3(-0.15, 1.45, 0.85),
		"cancel_start": 6, "cancel_end": 18, "cancel_into": [&"brawler_jab2"] + finishers,
	}))
	moves.append(_mk(light_common, {
		"id": &"brawler_jab2", "pose": &"jab2", "startup": 5, "active": 3, "recovery": 12,
		"damage": 30.0, "hitstun": 20, "knockback": Vector3(0, 0, 1.5),
		"hitbox_offset": Vector3(0.15, 1.45, 0.85),
		"cancel_start": 6, "cancel_end": 18, "cancel_into": [&"brawler_hook"] + finishers,
	}))
	moves.append(_mk(light_common, {
		"id": &"brawler_hook", "pose": &"hook", "startup": 7, "active": 3, "recovery": 14,
		"damage": 40.0, "hitstun": 22, "knockback": Vector3(-0.5, 0, 2.0),
		"hitbox_offset": Vector3(0.1, 1.4, 0.85), "hitbox_radius": 0.5,
		"cancel_start": 8, "cancel_end": 22, "cancel_into": [&"brawler_kick"] + finishers,
	}))
	moves.append(_mk(light_common, {
		"id": &"brawler_kick", "pose": &"kick", "startup": 9, "active": 4, "recovery": 18,
		"damage": 55.0, "hitstun": 26, "knockback": Vector3(0, 0, 3.5), "guard_damage": 8.0,
		"hitbox_offset": Vector3(0.1, 1.0, 0.95), "hitbox_radius": 0.5,
		"cancel_start": 10, "cancel_end": 26, "cancel_into": finishers,
	}))
	var finisher := {
		"button": HEAVY, "active": 4, "hitstun": 30, "knockdown": true, "is_heavy": true,
		"guard_stun": 18, "guard_damage": 35.0, "hitbox_radius": 0.55,
		"lunge_speed": 3.0, "lunge_frames": 8, "special_cancelable": true,
		"cancel_start": 12, "cancel_end": 30, "cancel_requires_hit": true,
	}
	# High: launcher (juggle / teleport chase). Whiffs over a duck.
	moves.append(_mk(finisher, {
		"id": &"brawler_finisher_high", "pose": &"kick_high", "height": HIGH,
		"startup": 10, "recovery": 26, "damage": 70.0, "knockback": Vector3(0, 8.0, 2.0),
		"hitbox_offset": Vector3(0.1, 1.65, 0.85), "hitbox_radius": 0.45,
	}))
	# Mid: blows the victim away.
	moves.append(_mk(finisher, {
		"id": &"brawler_finisher", "pose": &"kick_mid",
		"startup": 10, "recovery": 26, "damage": 80.0, "knockback": Vector3(0, 6.0, 6.0),
		"hitbox_offset": Vector3(0.1, 1.15, 0.9),
	}))
	# Low: sweep, short trip.
	moves.append(_mk(finisher, {
		"id": &"brawler_finisher_low", "pose": &"kick_low", "height": LOW,
		"startup": 10, "recovery": 28, "damage": 70.0, "knockback": Vector3(0, 3.0, 2.0),
		"hitbox_offset": Vector3(0.1, 0.35, 0.95), "hitbox_radius": 0.5, "guard_damage": 25.0,
	}))
	# --- Standalone HEAVY: directional kicks (guard crushers). Holding charges --
	var kick := {
		"button": HEAVY, "active": 4, "is_heavy": true, "special_cancelable": true,
		"cancel_requires_hit": true, "charge_move": &"brawler_charge_kick",
	}
	moves.append(_mk(kick, {
		"id": &"brawler_kick_high", "pose": &"kick_high", "height": HIGH,
		"startup": 13, "recovery": 22, "damage": 70.0, "hitstun": 30,
		"knockback": Vector3(0, 6.5, 2.0), "knockdown": true, "guard_stun": 16, "guard_damage": 30.0,
		"hitbox_offset": Vector3(0.1, 1.65, 0.9), "hitbox_radius": 0.45,
		"lunge_speed": 3.0, "lunge_frames": 10, "cancel_start": 15, "cancel_end": 32,
	}))
	moves.append(_mk(kick, {
		"id": &"brawler_kick_mid", "pose": &"kick_mid",
		"startup": 14, "recovery": 22, "damage": 90.0, "hitstun": 30,
		"knockback": Vector3(0, 0, 7.0), "guard_stun": 20, "guard_damage": 45.0,
		"hitbox_offset": Vector3(0.1, 1.15, 0.95), "hitbox_radius": 0.55,
		"lunge_speed": 4.0, "lunge_frames": 12, "cancel_start": 16, "cancel_end": 34,
	}))
	moves.append(_mk(kick, {
		"id": &"brawler_kick_low", "pose": &"kick_low", "height": LOW,
		"startup": 13, "recovery": 24, "damage": 65.0, "hitstun": 28,
		"knockback": Vector3(0, 2.5, 1.5), "knockdown": true, "guard_stun": 14, "guard_damage": 25.0,
		"hitbox_offset": Vector3(0.1, 0.35, 0.95), "hitbox_radius": 0.5,
		"lunge_speed": 2.5, "lunge_frames": 8, "cancel_start": 15, "cancel_end": 34,
	}))
	# --- Charge strikes: hold at charge_frame, release early or at full -------
	var charged := {
		"active": 4, "is_heavy": true, "hitbox_radius": 0.55, "special_cancelable": true,
		"cancel_requires_hit": true,
	}
	moves.append(_mk(charged, {
		"id": &"brawler_charge_punch", "pose": &"heavy", "startup": 18, "recovery": 24,
		"charge_frame": 10, "charge_max_frames": 45, "charge_damage_mult": 2.2, "charge_guard_mult": 3.0,
		"damage": 55.0, "hitstun": 26, "knockback": Vector3(0, 0, 4.5),
		"guard_stun": 16, "guard_damage": 15.0, "hitbox_offset": Vector3(0.1, 1.4, 0.9),
		"lunge_speed": 6.5, "lunge_start": 10, "lunge_frames": 8, "cancel_start": 22, "cancel_end": 40,
	}))
	moves.append(_mk(charged, {
		"id": &"brawler_charge_kick", "pose": &"charge_kick", "startup": 20, "recovery": 26,
		"charge_frame": 12, "charge_max_frames": 60, "charge_damage_mult": 2.0, "charge_guard_mult": 3.0,
		"damage": 70.0, "hitstun": 28, "knockback": Vector3(0, 0, 6.0),
		"guard_stun": 20, "guard_damage": 20.0, "hitbox_offset": Vector3(0.1, 1.15, 0.95),
		"lunge_speed": 7.0, "lunge_start": 12, "lunge_frames": 8, "cancel_start": 24, "cancel_end": 44,
	}))
	# --- Air / dash -------------------------------------------------------------
	moves.append(_mk({}, {
		"id": &"brawler_jump_kick", "button": LIGHT, "pose": &"jump_kick",
		"startup": 6, "active": 8, "recovery": 10, "damage": 50.0, "hitstun": 24,
		"knockback": Vector3(0, 0, 3.0), "guard_stun": 12, "guard_damage": 10.0,
		"hitbox_offset": Vector3(0.1, 0.7, 0.8), "hitbox_radius": 0.55,
	}))
	moves.append(_mk({}, {
		"id": &"brawler_dash_punch", "button": LIGHT, "pose": &"dash_punch",
		"startup": 6, "active": 5, "recovery": 18, "damage": 60.0, "hitstun": 26,
		"knockback": Vector3(0, 3.0, 6.0), "knockdown": true, "is_heavy": true,
		"guard_stun": 14, "guard_damage": 20.0, "hitbox_offset": Vector3(0, 1.3, 0.9),
		"hitbox_radius": 0.55, "lunge_speed": 10.0, "lunge_frames": 10,
	}))
	# --- Ki blast ---------------------------------------------------------------
	var blast_hit := _mk({}, {
		"id": &"brawler_ki_blast_shot", "pose": &"", "active": 1, "damage": 25.0, "hitstun": 16,
		"knockback": Vector3(0, 0, 2.0), "guard_stun": 8, "guard_damage": 6.0, "hitstop": 3,
		"hitbox_offset": Vector3(0.2, 1.35, 0.8), "hitbox_radius": 0.3,
		"travel_speed": 22.0, "lifetime_frames": 70, "ki_gain": -2.0,
	})
	_save_move(blast_hit)
	moves.append(_mk({}, {
		"id": &"brawler_ki_blast", "button": BLAST, "pose": &"ki_blast",
		"startup": 8, "active": 0, "recovery": 16, "damage": 0.0,
		"spawn_kind": &"ki_blast", "spawn_frame": 8, "spawn_move": blast_hit,
	}))
	# --- Super 1: rush (auto combo when the first hit lands) -------------------
	var rush := {"grants_hit_ki": false, "guard_stun": 12, "guard_damage": 15.0, "hitbox_radius": 0.55,
		"hitstop": 3, "special_cancelable": false}
	moves.append(_mk(rush, {
		"id": &"brawler_rush", "pose": &"dash_punch", "startup": 8, "active": 6, "recovery": 30,
		"damage": 40.0, "hitstun": 40, "knockback": Vector3(0, 0, 0.5),
		"hitbox_offset": Vector3(0, 1.3, 0.9), "lunge_speed": 14.0, "lunge_frames": 14,
		"track_frames": 14, "auto_next_on_hit": &"brawler_rush_2",
	}))
	var chain := [[&"brawler_rush_2", &"jab", &"brawler_rush_3"], [&"brawler_rush_3", &"hook", &"brawler_rush_4"],
		[&"brawler_rush_4", &"kick", &"brawler_rush_finish"]]
	for c: Array in chain:
		moves.append(_mk(rush, {
			"id": c[0], "pose": c[1], "startup": 3, "active": 2, "recovery": 6,
			"damage": 35.0, "hitstun": 30, "knockback": Vector3(0, 0, 0.5),
			"hitbox_offset": Vector3(0, 1.3, 0.85), "lunge_speed": 2.0, "lunge_frames": 4,
			"auto_next_on_hit": c[2],
		}))
	moves.append(_mk(rush, {
		"id": &"brawler_rush_finish", "pose": &"finisher", "startup": 6, "active": 3, "recovery": 28,
		"damage": 120.0, "hitstun": 40, "knockback": Vector3(0, 8.0, 9.0), "knockdown": true,
		"is_heavy": true, "hitstop": 14, "hitbox_offset": Vector3(0, 1.3, 0.85),
	}))
	# --- Super 2: beam (forward + SPECIAL) -----------------------------------------
	var beam_hit := _mk({}, {
		"id": &"brawler_beam_shot", "active": 60, "damage": 18.0, "hitstun": 18,
		"knockback": Vector3(0, 0, 1.0), "guard_stun": 12, "guard_damage": 12.0, "hitstop": 1,
		"multi_hit_interval": 6, "grants_hit_ki": false, "is_heavy": true,
		"hitbox_offset": Vector3(0, 1.35, 0.6), "hitbox_radius": 0.7, "hitbox_length": 18.0,
	})
	_save_move(beam_hit)
	moves.append(_mk({}, {
		"id": &"brawler_beam", "pose": &"beam", "startup": 18, "active": 0, "recovery": 80,
		"damage": 0.0, "spawn_kind": &"beam", "spawn_frame": 18, "spawn_move": beam_hit,
	}))
	# --- Ultimate: bigger beam (back + SPECIAL, full gauge) -----------------
	var ult_hit := _mk({}, {
		"id": &"brawler_ultimate_shot", "active": 100, "damage": 22.0, "hitstun": 18,
		"knockback": Vector3(0, 0, 1.0), "guard_stun": 14, "guard_damage": 25.0, "hitstop": 1,
		"multi_hit_interval": 5, "grants_hit_ki": false, "is_heavy": true,
		"hitbox_offset": Vector3(0, 1.3, 0.6), "hitbox_radius": 1.4, "hitbox_length": 22.0,
	})
	_save_move(ult_hit)
	moves.append(_mk({}, {
		"id": &"brawler_ultimate", "pose": &"beam", "startup": 30, "active": 0, "recovery": 120,
		"damage": 0.0, "spawn_kind": &"beam", "spawn_frame": 30, "spawn_move": ult_hit,
	}))

	for m: Resource in moves:
		_save_move(m)

	var d := CharacterDefScript.new()
	d.id = &"brawler"
	d.display_name = "Brawler"
	d.color = Color(0.85, 0.35, 0.15)
	var typed: Array[MoveData] = []
	for m: Resource in moves:
		typed.append(load(m.resource_path))
	d.moves = typed
	d.light_string.assign([&"brawler_jab1", &"brawler_jab2", &"brawler_hook", &"brawler_kick"])
	d.heavy = &"brawler_kick_mid"
	d.heavy_high = &"brawler_kick_high"
	d.heavy_low = &"brawler_kick_low"
	d.finisher = &"brawler_finisher"
	d.jump_attack = &"brawler_jump_kick"
	d.dash_attack = &"brawler_dash_punch"
	d.ki_blast = &"brawler_ki_blast"
	d.super1 = &"brawler_rush"
	d.super2 = &"brawler_beam"
	d.ultimate = &"brawler_ultimate"
	return d


## New MoveData from a shared base dict overlaid with specifics.
func _mk(base: Dictionary, props: Dictionary) -> Resource:
	var m := MoveDataScript.new()
	for src: Dictionary in [base, props]:
		for k: String in src:
			var v: Variant = src[k]
			if k == "cancel_into":
				var arr: Array[StringName] = []
				for x: StringName in v:
					arr.append(x)
				v = arr
			m.set(k, v)
	return m


func _save_move(m: Resource) -> void:
	var path := MOVES_DIR + String(m.id) + ".tres"
	var err := ResourceSaver.save(m, path)
	m.take_over_path(path)  # later saves reference this file instead of embedding
	print("write ", path, " -> ", error_string(err))


func _save_char(d: Resource) -> void:
	var path := CHAR_DIR + String(d.id) + ".tres"
	var err := ResourceSaver.save(d, path)
	print("write ", path, " -> ", error_string(err))
