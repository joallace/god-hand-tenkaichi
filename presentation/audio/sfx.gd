extends Node
## Autoload "Sfx": plays the sfxr-generated sounds in assets/sfx/ by name
## (file basename, e.g. &"hit_heavy"). One-shots share a small voice pool;
## loops are keyed so callers can stop them (e.g. one ki charge per fighter).
## Mixing comes from Tuning.sfx; menu sounds play on Tuning.sfx.ui_bus, the
## rest on Tuning.sfx.bus (player volumes per bus: Settings.audio). Missing
## sounds are silently skipped.
##
## Menus get a focus-move blip automatically; buttons/back call play().
## Regenerate sounds with: godot --headless --script res://tools/generate_sfx.gd

const DIR := "res://assets/sfx/"
## Sounds whose stream is set to loop on load.
const LOOPED: Array[StringName] = [&"ki_charge_loop"]
const SILENT_DB := -80.0

var _streams: Dictionary = {}  # StringName -> AudioStream
var _pool: Array[AudioStreamPlayer] = []
var _next_voice := 0
var _loops: Dictionary = {}  # Variant key -> AudioStreamPlayer
var _last_focus: Control


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_load_streams()
	for i in maxi(Tuning.sfx.voices, 1):
		var p := AudioStreamPlayer.new()
		p.name = "Voice%d" % i
		p.bus = Tuning.sfx.bus
		add_child(p)
		_pool.append(p)
	get_viewport().gui_focus_changed.connect(_on_focus_changed)


func _load_streams() -> void:
	for file in ResourceLoader.list_directory(DIR):
		if file.get_extension() != "wav":
			continue
		var id := StringName(file.get_basename())
		var s := load(DIR + file) as AudioStream
		if s is AudioStreamWAV and id in LOOPED:
			var w := (s as AudioStreamWAV).duplicate() as AudioStreamWAV
			w.loop_mode = AudioStreamWAV.LOOP_FORWARD
			w.loop_begin = 0
			w.loop_end = int(w.get_length() * w.mix_rate)
			s = w
		if s != null:
			_streams[id] = s


func has(id: StringName) -> bool:
	return _streams.has(id)


func volume_for(id: StringName) -> float:
	var t := Tuning.sfx
	return t.master_volume_db + t.volume_db.get(id, 0.0)


## The bus `id` plays on (menu sounds vs gameplay).
func bus_for(id: StringName) -> StringName:
	var t := Tuning.sfx
	return t.ui_bus if String(id).begins_with(t.ui_sound_prefix) or id in t.ui_sounds else t.bus


## Play a one-shot. Returns the voice (or null if muted/missing).
func play(id: StringName, pitch: float = 1.0) -> AudioStreamPlayer:
	var s: AudioStream = _streams.get(id)
	if s == null or not Tuning.sfx.enabled:
		return null
	var p := _free_voice()
	p.stream = s
	p.bus = bus_for(id)
	p.volume_db = volume_for(id)
	p.pitch_scale = maxf(pitch, 0.01)
	p.play()
	return p


## play() with a small random pitch variation (Tuning.sfx.pitch_jitter).
func play_varied(id: StringName, pitch: float = 1.0) -> AudioStreamPlayer:
	var j := Tuning.sfx.pitch_jitter
	return play(id, pitch * randf_range(1.0 - j, 1.0 + j))


## Start a looping sound under `key` (no-op if that key is already playing).
## Loop voices pause with the scene tree, unlike one-shots.
func start_loop(key: Variant, id: StringName) -> void:
	var s: AudioStream = _streams.get(id)
	if _loops.has(key) or s == null or not Tuning.sfx.enabled:
		return
	var p := AudioStreamPlayer.new()
	p.name = "Loop"
	p.process_mode = Node.PROCESS_MODE_PAUSABLE
	p.bus = bus_for(id)
	p.stream = s
	p.volume_db = volume_for(id)
	add_child(p)
	p.play()
	_loops[key] = p


func is_looping(key: Variant) -> bool:
	return _loops.has(key)


## Fade out and free the loop under `key`.
func stop_loop(key: Variant) -> void:
	var p: AudioStreamPlayer = _loops.get(key)
	if p == null:
		return
	_loops.erase(key)
	var tw := p.create_tween()
	tw.tween_property(p, "volume_db", SILENT_DB, Tuning.sfx.loop_fade_out)
	tw.tween_callback(p.queue_free)


func stop_all_loops() -> void:
	for key: Variant in _loops.keys():
		stop_loop(key)


## An idle voice, else the next one round-robin (cuts the oldest sound).
func _free_voice() -> AudioStreamPlayer:
	for p in _pool:
		if not p.playing:
			return p
	_next_voice = (_next_voice + 1) % _pool.size()
	return _pool[_next_voice]


## Blip when focus moves between controls (not on a screen's initial focus).
func _on_focus_changed(c: Control) -> void:
	var had_focus := is_instance_valid(_last_focus) and _last_focus.is_visible_in_tree()
	_last_focus = c
	if had_focus:
		play(&"ui_move")
