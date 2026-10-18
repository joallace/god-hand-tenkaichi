extends Node
## Headless test for the sfxr sound pipeline and the Sfx autoload:
## .sfs round-trip, deterministic rendering, every sound generated + loaded,
## one-shot / loop playback.
##   godot --headless res://tests/sfx_test.tscn

const SfxrParams := preload("res://tools/sfxr/sfxr_params.gd")
const SfxrSynth := preload("res://tools/sfxr/sfxr_synth.gd")
const Generator := preload("res://tools/generate_sfx.gd")

const TMP_SFS := "user://sfx_test_roundtrip.sfs"

var _ok := true


func _check(cond: bool, what: String) -> void:
	if not cond:
		_ok = false
		printerr("FAIL: ", what)


func _ready() -> void:
	_test_sfs_roundtrip()
	_test_render()
	_test_assets()
	_test_playback()
	# Let the loop fade out and the audio server release finished playbacks
	# (it does so asynchronously), else quitting reports leaked streams.
	await get_tree().create_timer(Tuning.sfx.loop_fade_out + 0.5).timeout
	_check(Sfx.find_children("Loop*", "AudioStreamPlayer", false, false).is_empty(), "stopped loop freed")
	print("SFX TEST %s" % ("PASS" if _ok else "FAIL"))
	get_tree().quit(0 if _ok else 1)


func _test_sfs_roundtrip() -> void:
	var a: SfxrParams = SfxrParams.from_dict(Generator.PRESETS["hit_heavy"])
	a.filter_on = true
	a.sound_vol = 0.3
	_check(a.save_sfs(TMP_SFS) == OK, "save .sfs")
	_check(FileAccess.get_file_as_bytes(TMP_SFS).size() == 105, "sfxr v102 .sfs is 105 bytes")
	var b := SfxrParams.new()
	_check(b.load_sfs(TMP_SFS) == OK, "load .sfs")
	_check(b.wave_type == a.wave_type, "wave_type round-trips")
	_check(is_equal_approx(b.sound_vol, a.sound_vol), "sound_vol round-trips")
	for field in SfxrParams.SFS_FIELDS:
		var va: Variant = a.get(field)
		var vb: Variant = b.get(field)
		_check(va == vb if field == &"filter_on" else is_equal_approx(va, vb), "%s round-trips" % field)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TMP_SFS))


func _test_render() -> void:
	var p: SfxrParams = SfxrParams.from_dict(Generator.PRESETS["ki_blast"])
	var s1 := SfxrSynth.render(p, 7)
	var s2 := SfxrSynth.render(p, 7)
	_check(s1.size() > 0 and s1 == s2, "render is deterministic")
	var bad := false
	for v in s1:
		bad = bad or is_nan(v) or absf(v) > 1.0
	_check(not bad, "samples finite and in -1..1")
	_check(SfxrSynth.peak(s1) > 0.0, "render is not silent")
	# Noise depends on the seed, tonal waves don't.
	var noise: SfxrParams = SfxrParams.from_dict(Generator.PRESETS["hit_light"])
	_check(SfxrSynth.render(noise, 1) != SfxrSynth.render(noise, 2), "noise uses the seed")


func _test_assets() -> void:
	for name: String in Generator.PRESETS:
		_check(FileAccess.file_exists(Generator.SFS_DIR + name + ".sfs"), "%s.sfs exists" % name)
		_check(Sfx.has(StringName(name)), "Sfx loaded %s.wav (run tools/generate_sfx.gd)" % name)
	for file in DirAccess.get_files_at(Generator.SFS_DIR):
		if file.get_extension() == "sfs":
			_check(Sfx.has(StringName(file.get_basename())), "%s rendered" % file)


func _test_playback() -> void:
	var v := Sfx.play(&"hit_light")
	_check(v != null and v.playing, "one-shot plays")
	_check(Sfx.play(&"no_such_sound") == null, "missing sound is skipped")
	for i in Tuning.sfx.voices + 4:
		Sfx.play(&"ui_move")  # more than the pool: must not error
	Sfx.start_loop(self, &"ki_charge_loop")
	_check(Sfx.is_looping(self), "loop started")
	Sfx.start_loop(self, &"ki_charge_loop")
	_check(Sfx.find_children("Loop*", "AudioStreamPlayer", false, false).size() == 1, "loop key is unique")
	Sfx.stop_loop(self)
	_check(not Sfx.is_looping(self), "loop stopped")
