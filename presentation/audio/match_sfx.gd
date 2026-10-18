class_name MatchSfx
extends Node
## Plays match sound effects (through the Sfx autoload) in response to fighter
## events, fighter state changes and director signals. Observes only; never
## touches gameplay state. Sounds are non-positional: with split screen there
## is no single listener, so both players hear everything equally.
##
## Fighter events: see Fighter's header. State changes: attack (swing whoosh
## unless the move spawns a projectile or is a charge strike), dash, jump, charge (ki loop while in
## the state). Director: round start, FIGHT, KO/time-up, last-seconds ticks,
## match won.

var director: MatchDirector
var hub: MatchEventHub


func _init() -> void:
	name = "MatchSfx"


func setup(p_director: MatchDirector, p_hub: MatchEventHub) -> void:
	director = p_director
	hub = p_hub
	hub.fighter_event.connect(_on_fighter_event)
	director.fighters_spawned.connect(_on_fighters_spawned)
	director.round_started.connect(_on_round_started)
	director.phase_changed.connect(_on_phase_changed)
	director.round_ended.connect(_on_round_ended)
	director.match_ended.connect(_on_match_ended)
	director.timer_changed.connect(_on_timer_changed)


func _exit_tree() -> void:
	Sfx.stop_all_loops()


func _on_fighters_spawned(fighters: Array[Fighter]) -> void:
	for f in fighters:
		f.state_changed.connect(_on_state_changed.bind(f))


func _on_fighter_event(_f: Fighter, kind: StringName, data: Dictionary) -> void:
	match kind:
		&"hit":
			var t := Tuning.sfx
			var combo: int = data.get("combo", 0)
			var pitch := 1.0 + minf(maxi(combo - 1, 0) * t.combo_pitch_step, t.combo_pitch_max)
			if data.get("blocked", false):
				Sfx.play_varied(&"hit_block")
			elif data.get("heavy", false):
				Sfx.play_varied(&"hit_heavy", pitch)
			else:
				Sfx.play_varied(&"hit_light", pitch)
		&"super_start":
			match data.get("kind", &""):
				&"rush": Sfx.play(&"super_rush")
				&"beam": Sfx.play(&"beam_charge")
		&"ultimate_start":
			Sfx.play(&"ultimate")
		&"charge_start":
			Sfx.play(&"ki_charge_start")
		&"charge_release":
			Sfx.play_varied(&"swing_heavy")
		&"beam":
			Sfx.play(&"beam_fire")
		&"perfect_dodge", &"dodge", &"guard_break", &"stagger", &"teleport", \
				&"vanish", &"reappear", &"ki_blast", &"not_enough_ki", \
				&"knockdown", &"ko", &"vanish_battle_end":
			Sfx.play_varied(kind)


func _on_state_changed(state_name: StringName, f: Fighter) -> void:
	if state_name == &"charge":
		if not Sfx.is_looping(f):
			Sfx.play(&"ki_charge_start")
			Sfx.start_loop(f, &"ki_charge_loop")
		return
	Sfx.stop_loop(f)
	match state_name:
		&"attack":
			var m := f.current_move()
			# Charge strikes whoosh on release (charge_release), not on windup.
			if m != null and m.spawn_kind == &"" and not m.is_charge_strike():
				Sfx.play_varied(&"swing_heavy" if m.is_heavy else &"swing_light")
		&"dash":
			Sfx.play_varied(&"dash")
		&"jump":
			Sfx.play_varied(&"jump")


func _on_round_started(_round_number: int) -> void:
	Sfx.stop_all_loops()
	Sfx.play(&"round_start")


func _on_phase_changed(phase: MatchDirector.Phase) -> void:
	if phase == MatchDirector.Phase.FIGHT:
		Sfx.play(&"fight")


func _on_round_ended(_winner_slot: int, reason: StringName) -> void:
	Sfx.stop_all_loops()
	if reason != &"ko":  # KO already played its own sound via the fighter event
		Sfx.play(&"time_up")


func _on_match_ended(_winner_slot: int) -> void:
	Sfx.play(&"match_win")


func _on_timer_changed(seconds_left: int) -> void:
	var warn := Tuning.sfx.timer_warning_seconds
	if director.phase == MatchDirector.Phase.FIGHT and seconds_left > 0 and seconds_left <= warn:
		Sfx.play(&"timer_tick")
