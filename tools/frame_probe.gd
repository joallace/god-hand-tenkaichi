extends Node
## Frame-time probe for presentation hitches (stutter on hits, blasts, supers).
## Runs the real match scene, so it measures what a player sees, unlike the
## headless sim benches. Desktop or browser (the web build is where GDScript
## is slowest: WASM, single thread, WebGL2):
##   godot res://tools/frame_probe.tscn -- mode=fight frames=2400 level=9
##   tools/web_probe.sh mode=events          # same probe in Chrome (web build)
## Modes:
## - fight (default): CPU vs CPU (`level`), infinite timer. Per-frame wall
##   time; frames over `spike_ms` are printed with that frame's fighter
##   events. Summary: median/p95/p99/max, spikes with vs without events, and
##   frames that compiled render pipelines after warm-up (Forward+/Mobile
##   only; always 0 on Compatibility/web). Rendered at vsync this is real
##   frame pacing; headless with --fixed-fps 60 it is CPU cost only.
## - events: idle match; every `gap` frames fires one suspect alone (hit
##   sounds, hit sparks, shockwave, a synthetic heavy hit / knockdown event,
##   and "nothing" as the baseline) and prints the call's cost and the next
##   frame's wall time, `reps` rounds.
## - bench: per-call cost of the building blocks effects use (nodes,
##   materials, tweens, audio playback), averaged over a batch.
## Lines start with FRAME_PROBE; the last one is "FRAME_PROBE DONE".
## Args: `-- key=value` on desktop, `?key=value&...` in the page URL on web.

const TAG := "FRAME_PROBE"
const SUSPECTS: Array[StringName] = [
	&"sfx_hit_heavy", &"sfx_hit_light", &"sfx_ki_blast", &"sfx_knockdown",
	&"vfx_spark_heavy", &"vfx_spark_light", &"vfx_shockwave",
	&"event_hit_heavy", &"event_knockdown", &"nothing",
]
const PIPELINE_MONITORS := [
	Performance.PIPELINE_COMPILATIONS_CANVAS, Performance.PIPELINE_COMPILATIONS_MESH,
	Performance.PIPELINE_COMPILATIONS_SURFACE, Performance.PIPELINE_COMPILATIONS_DRAW,
	Performance.PIPELINE_COMPILATIONS_SPECIALIZATION,
]
## Frames skipped before measuring (loading, warm-up, round intro).
const SETTLE := 240
const BENCH_BATCH := 20

var _args := {"mode": "fight", "frames": 2400, "level": 9, "spike_ms": 25.0, "gap": 40, "reps": 3,
		"max_spikes": 40}
var _match: MatchScene
var _frame := 0
var _t0 := 0
var _events: Array[String] = []
var _wall: PackedFloat64Array = []
var _tagged: PackedByteArray = []
var _spikes_printed := 0
var _pipes_prev := 0
var _pipe_frames := 0
var _queue: Array[StringName] = []
var _pending := ""


func _ready() -> void:
	process_priority = -1000000  # first each frame: the previous frame is complete
	_parse_args()
	var mode: String = _args.mode
	var cfg := MatchConfig.from_defaults()
	cfg.round_time_seconds = 0
	cfg.rounds_to_win = MatchConfig.MAX_ROUNDS_TO_WIN
	for i in 2:
		var p := PlayerSlotConfig.new()
		p.slot = i
		p.input_kind = PlayerSlotConfig.InputKind.CPU
		p.cpu_level = int(_args.level) if mode == "fight" else 0
		cfg.players.append(p)
	Game.current_config = cfg
	_match = (load(Game.SCENE_MATCH) as PackedScene).instantiate()
	add_child(_match)
	_match.hub.fighter_event.connect(func(f: Fighter, kind: StringName, _d: Dictionary) -> void:
		_events.append("%d:%s" % [f.slot, kind]))
	for r in int(_args.reps):
		_queue.append_array(SUSPECTS)
	_out("start %s %s mode=%s %s" % [OS.get_name(), RenderingServer.get_current_rendering_method(), mode, _args])


func _parse_args() -> void:
	var pairs := PackedStringArray()
	if OS.has_feature("web"):
		var q: Variant = JavaScriptBridge.eval("window.location.search")
		if q is String:
			pairs = (q as String).trim_prefix("?").split("&", false)
	else:
		pairs = OS.get_cmdline_user_args()
	for a in pairs:
		var kv := a.split("=")
		if kv.size() != 2 or not _args.has(kv[0]):
			continue
		var cur: Variant = _args[kv[0]]
		_args[kv[0]] = int(kv[1]) if cur is int else (float(kv[1]) if cur is float else kv[1])


func _process(_delta: float) -> void:
	var now := Time.get_ticks_usec()
	var ms := (now - _t0) / 1000.0
	_frame += 1
	match _args.mode:
		"events":
			_tick_events(ms)
		"bench":
			if _frame == SETTLE:
				_bench()
				_finish()
		_:
			_tick_fight(ms)
	_events.clear()
	_t0 = Time.get_ticks_usec()


func _tick_fight(ms: float) -> void:
	var pipes := _pipeline_compiles()
	if _frame > SETTLE:
		var has_events := not _events.is_empty()
		_wall.append(ms)
		_tagged.append(int(has_events))
		if pipes > _pipes_prev:
			_pipe_frames += 1
			_out("pipeline compiles frame %d: %d, events %s" % [_frame, pipes - _pipes_prev, _events])
		if ms > float(_args.spike_ms) and _spikes_printed < int(_args.max_spikes):
			_spikes_printed += 1
			_out("spike frame %d %.1f ms events %s" % [_frame, ms, _events])
	_pipes_prev = pipes
	if _frame >= SETTLE + int(_args.frames):
		_summary()
		_finish()


func _summary() -> void:
	var sorted := _wall.duplicate()
	sorted.sort()
	var n := sorted.size()
	var event_frames := 0
	var spikes_with := 0
	var spikes_without := 0
	var event_ms := 0.0
	var quiet_ms := 0.0
	for i in n:
		var spike := _wall[i] > float(_args.spike_ms)
		if _tagged[i]:
			event_frames += 1
			event_ms += _wall[i]
			spikes_with += int(spike)
		else:
			quiet_ms += _wall[i]
			spikes_without += int(spike)
	_out("frames %d median %.2f p95 %.2f p99 %.2f max %.2f ms" % [n, sorted[n / 2], sorted[int(n * 0.95)],
			sorted[int(n * 0.99)], sorted[n - 1]])
	_out("event frames %d (mean %.2f ms) quiet frames %d (mean %.2f ms)" % [event_frames,
			event_ms / maxi(event_frames, 1), n - event_frames, quiet_ms / maxi(n - event_frames, 1)])
	_out("spikes over %.1f ms: with events %d, without %d; frames compiling pipelines %d" % [
			float(_args.spike_ms), spikes_with, spikes_without, _pipe_frames])


func _tick_events(ms: float) -> void:
	if _pending != "":
		_out("  %-16s next frame %.1f ms" % [_pending, ms])
		_pending = ""
	if _frame < SETTLE or _frame % int(_args.gap) != 0:
		return
	if _queue.is_empty():
		_finish()
		return
	var s: StringName = _queue.pop_front()
	var t := Time.get_ticks_usec()
	_fire(s)
	_out("%-16s call %.2f ms" % [s, (Time.get_ticks_usec() - t) / 1000.0])
	_pending = s


func _fire(s: StringName) -> void:
	var victim := _match.director.fighters[1]
	var pos := victim.global_position + Vector3.UP
	var v := Tuning.vfx
	match s:
		&"sfx_hit_heavy": Sfx.play_varied(&"hit_heavy")
		&"sfx_hit_light": Sfx.play_varied(&"hit_light")
		&"sfx_ki_blast": Sfx.play(&"ki_blast")
		&"sfx_knockdown": Sfx.play_varied(&"knockdown")
		&"vfx_spark_heavy":
			_match.vfx.hit_spark(pos, v.heavy_hit_color, v.heavy_flash_size, v.heavy_duration, v.spark_count_heavy)
		&"vfx_spark_light":
			_match.vfx.hit_spark(pos, v.hit_color, v.hit_flash_size, v.hit_duration, v.spark_count_light)
		&"vfx_shockwave":
			_match.vfx.shockwave(pos, v.heavy_hit_color, v.heavy_flash_size * 2.0, v.heavy_duration)
		&"event_hit_heavy":
			victim.event.emit(&"hit", {"attacker_slot": 0, "damage": 1.0, "position": pos, "heavy": true,
					"blocked": false})
		&"event_knockdown":
			victim.event.emit(&"knockdown", {"attacker_slot": 0, "position": pos})


func _bench() -> void:
	var sphere := SphereMesh.new()
	var nodes: Array[MeshInstance3D] = []
	var mats: Array[StandardMaterial3D] = []
	var t := Time.get_ticks_usec()
	for i in BENCH_BATCH:
		var mi := MeshInstance3D.new()
		mi.mesh = sphere
		_match.vfx.add_child(mi)
		nodes.append(mi)
	_bench_line("MeshInstance3D new + add_child", t)
	t = Time.get_ticks_usec()
	for i in BENCH_BATCH:
		mats.append(FxMaterials.make(FxMaterials.Kind.TRANSLUCENT_ON_TOP, Color.RED))
	_bench_line("FxMaterials.make", t)
	t = Time.get_ticks_usec()
	for i in BENCH_BATCH:
		FxMaterials.template(FxMaterials.Kind.TRANSLUCENT_ON_TOP).duplicate()
	_bench_line("StandardMaterial3D.duplicate()", t)
	t = Time.get_ticks_usec()
	for i in BENCH_BATCH:
		nodes[i].material_override = mats[i]
	_bench_line("material_override assign", t)
	t = Time.get_ticks_usec()
	for i in BENCH_BATCH:
		var tw := nodes[i].create_tween().set_parallel()
		tw.tween_property(nodes[i], "scale", Vector3.ONE * 2.0, 0.3)
		tw.tween_property(mats[i], "albedo_color:a", 0.0, 0.3)
		tw.chain().tween_callback(nodes[i].queue_free)
	_bench_line("tween (2 props + free)", t)
	t = Time.get_ticks_usec()
	for i in BENCH_BATCH:
		mats[i].albedo_color = Color(1, 0, 0, 0.5)
		nodes[i].position = Vector3(0, 1, 0)
		nodes[i].scale = Vector3.ONE * 1.5
	_bench_line("reuse: color + position + scale", t)
	var p := AudioStreamPlayer.new()
	p.bus = Tuning.sfx.bus
	add_child(p)
	t = Time.get_ticks_usec()
	for i in BENCH_BATCH:
		Sfx.play(&"hit_heavy")
	_bench_line("Sfx.play", t)
	p.stream = load("res://assets/sfx/hit_light.wav")
	t = Time.get_ticks_usec()
	for i in BENCH_BATCH:
		p.play()
	_bench_line("AudioStreamPlayer.play (same stream)", t)
	p.queue_free()


func _bench_line(what: String, t: int) -> void:
	_out("bench %-36s %.3f ms each" % [what, (Time.get_ticks_usec() - t) / 1000.0 / BENCH_BATCH])


func _pipeline_compiles() -> int:
	var n := 0
	for m: int in PIPELINE_MONITORS:
		n += int(Performance.get_monitor(m))
	return n


func _finish() -> void:
	_out("DONE")
	set_process(false)
	get_tree().quit(0)


func _out(s: String) -> void:
	print("%s %s" % [TAG, s])
