extends Node
## Headless smoke test: builds a 2-player match, steps it, checks round flow
## and save/load. Run (as a scene, so autoloads exist):
##   godot --headless res://tests/smoke_match.tscn


func _ready() -> void:
	var cfg := MatchConfig.from_defaults()
	for i in 2:
		var p := PlayerSlotConfig.new()
		p.slot = i
		p.device_kind = Bindings.Kind.KEYBOARD
		cfg.players.append(p)
	var d := MatchDirector.new()
	d.auto_step = false
	add_child(d)
	d.setup(cfg)
	for i in 300:
		d.step()
	var ok := d.phase == MatchDirector.Phase.FIGHT
	var snap := d.save_state()
	for i in 10:
		d.step()
	d.load_state(snap)
	ok = ok and d.tick == snap["tick"]
	# Unpausing must not turn a still-held button into a fresh press.
	var held := ScriptedInput.new()
	held.start_tick = d.tick  # already held while paused
	held.press(0, InputFrame.Btn.JUMP, 1000)
	d.sources[0] = held
	d.paused = true
	d.paused = false
	d.step()
	var resync_ok := not held._previous.just_pressed(InputFrame.Btn.JUMP)
	print("RESYNC %s" % ("OK" if resync_ok else "FAIL"))
	ok = ok and resync_ok
	print("SMOKE %s tick=%d phase=%s" % ["OK" if ok else "FAIL", d.tick, MatchDirector.Phase.find_key(d.phase)])
	get_tree().quit(0 if ok else 1)
