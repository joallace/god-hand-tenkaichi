class_name AudioSettings
extends RefCounted
## Per-user volumes per audio bus (percent, 0 = muted), stored in
## `user://audio.cfg`; the Settings autoload owns one instance
## (`Settings.audio`) and applies it to the AudioServer buses. The mix
## itself (per-sound offsets) stays in Tuning.sfx.

const DEFAULT_PATH := "user://audio.cfg"
const MASTER := &"Master"
const _SECTION := "audio"
const MAX_PERCENT := 100

var path := DEFAULT_PATH
## bus name -> percent 0..MAX_PERCENT, for every bus in buses().
var volumes: Dictionary[StringName, int] = {}


func _init() -> void:
	reset_defaults()


static func load_from(p: String = DEFAULT_PATH) -> AudioSettings:
	var s := AudioSettings.new()
	s.path = p
	s.reload()
	return s


## The buses the player controls, in menu order.
static func buses() -> Array[StringName]:
	return [MASTER, Tuning.sfx.bus, Tuning.sfx.ui_bus]


func reset_defaults() -> void:
	volumes.clear()
	for b in buses():
		volumes[b] = Tuning.sfx.default_volume_percent


func reload() -> void:
	reset_defaults()
	var cf := ConfigFile.new()
	if cf.load(path) != OK:
		return
	for b in buses():
		var v: Variant = cf.get_value(_SECTION, String(b), volumes[b])
		if v is int:
			set_volume(b, v)


func save() -> Error:
	var cf := ConfigFile.new()
	for b in buses():
		cf.set_value(_SECTION, String(b), volumes[b])
	return cf.save(path)


func volume(bus: StringName) -> int:
	return volumes.get(bus, Tuning.sfx.default_volume_percent)


func set_volume(bus: StringName, percent: int) -> void:
	if volumes.has(bus):
		volumes[bus] = clampi(percent, 0, MAX_PERCENT)


## Push the volumes to the AudioServer (missing buses are skipped).
func apply() -> void:
	for b in buses():
		var idx := AudioServer.get_bus_index(b)
		if idx < 0:
			continue
		var p := volume(b)
		AudioServer.set_bus_mute(idx, p <= 0)
		AudioServer.set_bus_volume_db(idx, linear_to_db(float(maxi(p, 1)) / MAX_PERCENT))
