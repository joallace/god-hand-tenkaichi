class_name MatchSfx
extends Node
## Plays match sound effects (through the Sfx autoload) in response to fighter
## events, fighter state changes and director signals. Observes only; never
## touches gameplay state. Sounds are non-positional: with split screen there
## is no single listener, so both players hear everything equally.
##
## Streams (MatchEventHub, SPEC_ONLINE.md §9):
##   immediate — fighter events, state entries (attack swing whoosh unless the
##     move spawns a projectile or is a charge strike, dash, jump) and FIGHT:
##     deduplicated and muted while a rollback re-simulates.
##   confirmed — round start, KO/time-up, match won, co-op wave start / clear
##     and run end: they go with banners, so a rolled-back KO stays silent.
##   state — the ki charge loop (start sound + loop while in &"charge") starts
##     / stops on state entries and is reconciled with each fighter's current
##     state every frame, and last-seconds timer ticks follow the round timer,
##     so both are right after any resim.
## Fighter events: see Fighter's header. Blocked hits sound by guard result
## (ki guard buzz; push-offs are voiced by their own push_off event).
## Co-op: downed / revive_start / revived / out / lock_broken play their own
## sounds, an enemy's &"entry" plays enemy_entry, waves after the first play
## wave_start, wave clears before the last wave_clear, run_ended plays
## match_win / time_up; loops of fighters leaving the match stop.

var director: MatchDirector
var hub: MatchEventHub

var _last_seconds := -2


func _init() -> void:
	name = "MatchSfx"


func setup(p_director: MatchDirector, p_hub: MatchEventHub) -> void:
	director = p_director
	hub = p_hub
	hub.bind_director(director)
	hub.fighter_event.connect(_on_fighter_event)
	hub.fighter_state.connect(_on_state_changed)
	hub.director_event.connect(_on_director_event)
	hub.confirmed_event.connect(_on_confirmed_event)
	director.entity_removed.connect(_on_entity_removed)


func _exit_tree() -> void:
	Sfx.stop_all_loops()


func _process(_delta: float) -> void:
	if director == null:
		return
	_sync_charge_loops()
	_sync_timer()


## Ki charge loop = "fighter is in &"charge" now": state entries are muted
## during a resim, so the loop is also checked against the state each frame.
func _sync_charge_loops() -> void:
	for f in director.fighters:
		if is_instance_valid(f):
			_set_charge_loop(f, f.current_state_name() == &"charge")


func _set_charge_loop(f: Fighter, charging: bool) -> void:
	if charging and not Sfx.is_looping(f):
		Sfx.play(&"ki_charge_start")
		Sfx.start_loop(f, &"ki_charge_loop")
	elif not charging and Sfx.is_looping(f):
		Sfx.stop_loop(f)


## Last-seconds ticks follow the round timer's whole seconds.
func _sync_timer() -> void:
	var cfg := director.config
	if cfg == null:
		return
	var s := -1 if cfg.is_infinite_time() else ceili(maxi(director.round_frames_left, 0) / float(Tuning.match_rules.tick_rate))
	if s == _last_seconds:
		return
	_last_seconds = s
	var warn := Tuning.sfx.timer_warning_seconds
	if director.phase == MatchDirector.Phase.FIGHT and s > 0 and s <= warn:
		Sfx.play(&"timer_tick")


func _on_director_event(kind: StringName, data: Dictionary) -> void:
	if kind == &"phase_changed" and data["phase"] == MatchDirector.Phase.FIGHT:
		Sfx.play(&"fight")


func _on_confirmed_event(_tick: int, kind: StringName, data: Dictionary) -> void:
	match kind:
		&"round_started":
			Sfx.stop_all_loops()
			Sfx.play(&"round_start")
		&"round_ended":
			Sfx.stop_all_loops()
			if data["reason"] != &"ko":  # KO already played its own sound via the fighter event
				Sfx.play(&"time_up")
		&"match_ended":
			if not director.is_coop():  # run_ended picks the co-op sound
				Sfx.play(&"match_win")
		&"run_ended":
			Sfx.stop_all_loops()
			Sfx.play(&"match_win" if data["cleared"] else &"time_up")
		&"wave_started":
			if int(data["wave"]) > 0:  # the first: round_start / fight like a versus round
				Sfx.play(&"wave_start")
		&"wave_cleared":
			if not data["last"]:  # the last one's clear is covered by run_ended
				Sfx.play(&"wave_clear")


func _on_entity_removed(e: SimEntity) -> void:
	if e is Fighter:
		Sfx.stop_loop(e)


func _on_fighter_event(_f: Fighter, kind: StringName, data: Dictionary) -> void:
	match kind:
		&"hit":
			var t := Tuning.sfx
			var combo: int = data.get("combo", 0)
			var pitch := 1.0 + minf(maxi(combo - 1, 0) * t.combo_pitch_step, t.combo_pitch_max)
			if data.get("blocked", false):
				match data.get("guard_result", -1):
					MoveData.GuardResult.KI_GUARD:
						Sfx.play_varied(&"ki_guard")
					MoveData.GuardResult.PUSH_OFF, MoveData.GuardResult.PUSH_STOP:
						pass  # the push_off event plays its own clang
					_:
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
		&"entry":
			Sfx.play_varied(&"enemy_entry")
		&"downed", &"revive_start", &"revived", &"out", &"lock_broken":
			Sfx.play_varied(kind)
		&"perfect_dodge", &"dodge", &"guard_break", &"stagger", &"teleport", \
				&"vanish", &"reappear", &"ki_blast", &"not_enough_ki", \
				&"knockdown", &"ko", &"vanish_battle_end", &"push_off", \
				&"counter_guard", &"throw", &"throw_break", &"taunt", \
				&"taunt_done", &"ground_bounce":
			Sfx.play_varied(kind)


func _on_state_changed(f: Fighter, state_name: StringName) -> void:
	_set_charge_loop(f, state_name == &"charge")
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
