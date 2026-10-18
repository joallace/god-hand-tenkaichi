extends RefCounted
## One sfxr sound definition: the parameter set of DrPetter's sfxr (2007),
## with the same names, ranges and defaults. Reads/writes sfxr's binary .sfs
## "Save sound" format (versions 100-102), so files round-trip with sfxr.exe.
## Ranges: most are 0..1; *_ramp, freq_dramp, pha_offset, arp_mod are -1..1.

enum Wave { SQUARE, SAWTOOTH, SINE, NOISE }

const SFS_VERSION := 102
## Field order of the .sfs body after version/wave_type/sound_vol. `filter_on`
## is a 1-byte C++ bool; everything else is a 32-bit float.
const SFS_FIELDS: Array[StringName] = [
	&"base_freq", &"freq_limit", &"freq_ramp", &"freq_dramp",
	&"duty", &"duty_ramp",
	&"vib_strength", &"vib_speed", &"vib_delay",
	&"env_attack", &"env_sustain", &"env_decay", &"env_punch",
	&"filter_on",
	&"lpf_resonance", &"lpf_freq", &"lpf_ramp", &"hpf_freq", &"hpf_ramp",
	&"pha_offset", &"pha_ramp",
	&"repeat_speed",
	&"arp_speed", &"arp_mod",
]
## Fields missing from older .sfs versions (left at defaults when loading).
const V101_FIELDS: Array[StringName] = [&"freq_dramp", &"arp_speed", &"arp_mod"]

var wave_type: Wave = Wave.SQUARE
var sound_vol: float = 0.5

var base_freq: float = 0.3
var freq_limit: float = 0.0
var freq_ramp: float = 0.0
var freq_dramp: float = 0.0
var duty: float = 0.0
var duty_ramp: float = 0.0

var vib_strength: float = 0.0
var vib_speed: float = 0.0
var vib_delay: float = 0.0  # unused by sfxr's synth, kept for the file format

var env_attack: float = 0.0
var env_sustain: float = 0.3
var env_decay: float = 0.4
var env_punch: float = 0.0

var filter_on: bool = false  # unused by sfxr's synth, kept for the file format
var lpf_resonance: float = 0.0
var lpf_freq: float = 1.0
var lpf_ramp: float = 0.0
var hpf_freq: float = 0.0
var hpf_ramp: float = 0.0

var pha_offset: float = 0.0
var pha_ramp: float = 0.0

var repeat_speed: float = 0.0

var arp_speed: float = 0.0
var arp_mod: float = 0.0


## Params from a dictionary of overrides; unspecified fields keep sfxr defaults.
static func from_dict(d: Dictionary) -> RefCounted:
	var p: RefCounted = (load("res://tools/sfxr/sfxr_params.gd") as GDScript).new()
	for k: String in d:
		assert(k in p, "unknown sfxr param '%s'" % k)
		p.set(k, d[k])
	return p


func save_sfs(path: String) -> Error:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.big_endian = false
	f.store_32(SFS_VERSION)
	f.store_32(wave_type)
	f.store_float(sound_vol)
	for field in SFS_FIELDS:
		if field == &"filter_on":
			f.store_8(1 if filter_on else 0)
		else:
			f.store_float(get(field))
	return OK


func load_sfs(path: String) -> Error:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return FileAccess.get_open_error()
	f.big_endian = false
	var version := f.get_32()
	if version < 100 or version > SFS_VERSION:
		return ERR_FILE_UNRECOGNIZED
	wave_type = f.get_32() as Wave
	sound_vol = f.get_float() if version == 102 else 0.5
	for field in SFS_FIELDS:
		if version < 101 and field in V101_FIELDS:
			continue
		if field == &"filter_on":
			filter_on = f.get_8() != 0
		else:
			set(field, f.get_float())
	return ERR_FILE_CORRUPT if f.get_position() > f.get_length() else OK
