extends SceneTree
## Sound effects pipeline (sfxr):
##   1. writes data/sfx/<name>.sfs for every PRESETS entry that doesn't exist
##      yet (pass --force to overwrite with the presets below);
##   2. renders EVERY data/sfx/*.sfs to assets/sfx/<name>.wav, peak-normalized.
##   godot --headless --script res://tools/generate_sfx.gd [-- --force]
##
## The .sfs files are sfxr's own "Save sound" format: open one in sfxr.exe
## (`wine sfxr.exe`, then "LOAD SOUND"), tweak, "SAVE SOUND" over it, and rerun
## this script. Adding a sound: drop a new .sfs in data/sfx/ (or add a preset),
## rerun, then reference its name from presentation/audio/.
## Volume mixing happens in data/tuning/sfx.tres, not here.

const SfxrParams := preload("res://tools/sfxr/sfxr_params.gd")
const SfxrSynth := preload("res://tools/sfxr/sfxr_synth.gd")

const SFS_DIR := "res://data/sfx/"
const WAV_DIR := "res://assets/sfx/"
## Every render is scaled so its loudest sample hits this level.
const NORMALIZE_PEAK := 0.8

const SQUARE := SfxrParams.Wave.SQUARE
const SAW := SfxrParams.Wave.SAWTOOTH
const SINE := SfxrParams.Wave.SINE
const NOISE := SfxrParams.Wave.NOISE

## name -> sfxr parameter overrides (unlisted params keep sfxr's defaults:
## base_freq 0.3, env_sustain 0.3, env_decay 0.4, lpf_freq 1, others 0).
const PRESETS := {
	# --- combat ---------------------------------------------------------------
	"hit_light": {"wave_type": NOISE, "base_freq": 0.42, "freq_ramp": -0.35,
			"env_sustain": 0.1, "env_decay": 0.25, "env_punch": 0.6, "hpf_freq": 0.05},
	"hit_heavy": {"wave_type": NOISE, "base_freq": 0.22, "freq_ramp": -0.25,
			"env_sustain": 0.15, "env_decay": 0.38, "env_punch": 0.75,
			"pha_offset": 0.15, "pha_ramp": -0.1, "lpf_freq": 0.75, "lpf_resonance": 0.3},
	"hit_block": {"wave_type": SQUARE, "base_freq": 0.62, "freq_ramp": -0.45, "duty": 0.4,
			"env_sustain": 0.06, "env_decay": 0.22, "env_punch": 0.45, "hpf_freq": 0.25},
	"swing_light": {"wave_type": NOISE, "base_freq": 0.55, "freq_ramp": -0.2,
			"env_attack": 0.15, "env_sustain": 0.08, "env_decay": 0.22,
			"lpf_freq": 0.35, "lpf_ramp": 0.3, "hpf_freq": 0.2},
	"swing_heavy": {"wave_type": NOISE, "base_freq": 0.4, "freq_ramp": -0.15,
			"env_attack": 0.2, "env_sustain": 0.12, "env_decay": 0.3,
			"lpf_freq": 0.28, "lpf_ramp": 0.25, "lpf_resonance": 0.4, "hpf_freq": 0.1},
	"guard_break": {"wave_type": NOISE, "base_freq": 0.5, "freq_ramp": -0.3,
			"env_sustain": 0.15, "env_decay": 0.45, "env_punch": 0.8,
			"pha_offset": 0.35, "pha_ramp": -0.2, "hpf_freq": 0.05},
	"stagger": {"wave_type": SQUARE, "base_freq": 0.4, "freq_ramp": -0.2, "duty": 0.2,
			"vib_strength": 0.5, "vib_speed": 0.7, "env_sustain": 0.15, "env_decay": 0.35},
	"knockdown": {"wave_type": NOISE, "base_freq": 0.08, "freq_ramp": -0.1,
			"env_sustain": 0.08, "env_decay": 0.35, "env_punch": 0.6, "lpf_freq": 0.3},
	# Ki guard: a buzzy energy block, lower and longer than a plain block.
	"ki_guard": {"wave_type": SAW, "base_freq": 0.38, "freq_ramp": -0.3,
			"env_sustain": 0.08, "env_decay": 0.28, "env_punch": 0.5,
			"vib_strength": 0.25, "vib_speed": 0.75, "pha_offset": 0.15, "hpf_freq": 0.12},
	# Push-off: a bright, ringing clang as the guard repels the attacker.
	"push_off": {"wave_type": SQUARE, "base_freq": 0.72, "freq_ramp": -0.15, "duty": 0.15,
			"env_sustain": 0.05, "env_decay": 0.42, "env_punch": 0.7,
			"arp_speed": 0.7, "arp_mod": 0.35, "pha_offset": 0.08, "hpf_freq": 0.2},
	# Counter stance catching a hit: sharp parry ping rising.
	"counter_guard": {"wave_type": SINE, "base_freq": 0.55, "freq_ramp": 0.2,
			"env_sustain": 0.06, "env_decay": 0.35, "env_punch": 0.8,
			"arp_speed": 0.5, "arp_mod": 0.5, "hpf_freq": 0.15},
	# Grab connecting: short low cloth/body snatch.
	"throw": {"wave_type": NOISE, "base_freq": 0.2, "freq_ramp": 0.1,
			"env_sustain": 0.06, "env_decay": 0.2, "env_punch": 0.5,
			"lpf_freq": 0.45, "hpf_freq": 0.05},
	# Breaking a grab: a slap followed by a quick descending swish.
	"throw_break": {"wave_type": NOISE, "base_freq": 0.55, "freq_ramp": -0.35,
			"env_sustain": 0.05, "env_decay": 0.3, "env_punch": 0.65,
			"pha_offset": 0.2, "pha_ramp": -0.15, "hpf_freq": 0.18},
	# Bouncing off the floor: deep thud.
	"ground_bounce": {"wave_type": NOISE, "base_freq": 0.06, "freq_ramp": -0.08,
			"env_sustain": 0.1, "env_decay": 0.4, "env_punch": 0.8, "lpf_freq": 0.22},
	"ko": {"wave_type": NOISE, "base_freq": 0.12, "freq_ramp": -0.05,
			"env_sustain": 0.3, "env_decay": 0.75, "env_punch": 0.85,
			"pha_offset": -0.3, "pha_ramp": -0.15, "lpf_freq": 0.8, "lpf_ramp": -0.1},
	# --- movement / defense ---------------------------------------------------
	"jump": {"wave_type": SQUARE, "duty": 0.35, "base_freq": 0.32, "freq_ramp": 0.22,
			"env_sustain": 0.15, "env_decay": 0.22, "hpf_freq": 0.1},
	"dash": {"wave_type": NOISE, "base_freq": 0.3, "freq_ramp": 0.15,
			"env_attack": 0.08, "env_sustain": 0.12, "env_decay": 0.25,
			"lpf_freq": 0.5, "hpf_freq": 0.15},
	"dodge": {"wave_type": NOISE, "base_freq": 0.6, "freq_ramp": -0.1,
			"env_attack": 0.12, "env_sustain": 0.08, "env_decay": 0.28,
			"lpf_freq": 0.45, "lpf_ramp": -0.2, "hpf_freq": 0.3},
	"perfect_dodge": {"wave_type": SINE, "base_freq": 0.62, "env_sustain": 0.05,
			"env_decay": 0.4, "env_punch": 0.4, "arp_speed": 0.55, "arp_mod": 0.5,
			"vib_strength": 0.05, "vib_speed": 0.6, "pha_offset": 0.05},
	# --- ki / specials --------------------------------------------------------
	"teleport": {"wave_type": SQUARE, "base_freq": 0.3, "freq_ramp": 0.5, "freq_dramp": 0.2,
			"duty": 0.2, "duty_ramp": 0.3, "env_sustain": 0.15, "env_decay": 0.25,
			"pha_offset": 0.2, "pha_ramp": 0.3, "hpf_freq": 0.15},
	"vanish": {"wave_type": SAW, "base_freq": 0.75, "freq_ramp": -0.4,
			"env_sustain": 0.15, "env_decay": 0.32, "env_punch": 0.3,
			"pha_offset": 0.3, "pha_ramp": -0.2, "hpf_freq": 0.1},
	"reappear": {"wave_type": SQUARE, "base_freq": 0.5, "freq_ramp": -0.3, "duty": 0.3,
			"env_sustain": 0.08, "env_decay": 0.22, "hpf_freq": 0.2},
	"vanish_battle_end": {"wave_type": SQUARE, "base_freq": 0.45, "env_sustain": 0.06,
			"env_decay": 0.3, "env_punch": 0.5, "arp_speed": 0.6, "arp_mod": -0.3, "hpf_freq": 0.1},
	"ki_blast": {"wave_type": SAW, "base_freq": 0.7, "freq_limit": 0.2, "freq_ramp": -0.3,
			"env_sustain": 0.15, "env_decay": 0.3, "env_punch": 0.35,
			"pha_offset": 0.12, "hpf_freq": 0.12},
	"ki_charge_start": {"wave_type": SAW, "base_freq": 0.15, "freq_ramp": 0.3,
			"env_attack": 0.1, "env_sustain": 0.2, "env_decay": 0.35,
			"vib_strength": 0.2, "vib_speed": 0.5, "pha_offset": 0.2, "lpf_freq": 0.6},
	# Looped while charging: flat envelope so the loop seam is inaudible.
	"ki_charge_loop": {"wave_type": NOISE, "base_freq": 0.18, "env_sustain": 0.75,
			"env_decay": 0.0, "lpf_freq": 0.4, "lpf_resonance": 0.5,
			"vib_strength": 0.3, "vib_speed": 0.4, "pha_offset": 0.25},
	# Taunt: cocky two-note "wah-wah" warble.
	"taunt": {"wave_type": SQUARE, "base_freq": 0.35, "duty": 0.3,
			"env_sustain": 0.25, "env_decay": 0.3, "arp_speed": 0.5, "arp_mod": -0.25,
			"vib_strength": 0.2, "vib_speed": 0.45, "lpf_freq": 0.7},
	# Taunt finished: ki surges up.
	"taunt_done": {"wave_type": SAW, "base_freq": 0.25, "freq_ramp": 0.35,
			"env_sustain": 0.1, "env_decay": 0.3, "env_punch": 0.3,
			"pha_offset": 0.2, "pha_ramp": 0.1, "lpf_freq": 0.7},
	"not_enough_ki": {"wave_type": SQUARE, "base_freq": 0.16, "freq_ramp": -0.05,
			"env_sustain": 0.2, "env_decay": 0.2, "lpf_freq": 0.6},
	"super_rush": {"wave_type": SQUARE, "base_freq": 0.25, "freq_ramp": 0.3, "duty": 0.4,
			"duty_ramp": -0.2, "env_sustain": 0.25, "env_decay": 0.38,
			"vib_strength": 0.15, "vib_speed": 0.6, "repeat_speed": 0.55},
	"beam_charge": {"wave_type": SAW, "base_freq": 0.12, "freq_ramp": 0.2,
			"env_attack": 0.3, "env_sustain": 0.4, "env_decay": 0.2,
			"vib_strength": 0.15, "vib_speed": 0.7, "pha_offset": 0.3, "pha_ramp": 0.1,
			"lpf_freq": 0.5, "lpf_ramp": 0.15},
	"beam_fire": {"wave_type": NOISE, "base_freq": 0.3, "env_sustain": 0.55,
			"env_decay": 0.55, "env_punch": 0.5, "pha_offset": 0.2, "pha_ramp": 0.05,
			"lpf_freq": 0.6, "lpf_resonance": 0.3, "vib_strength": 0.2, "vib_speed": 0.3},
	"ultimate": {"wave_type": SAW, "base_freq": 0.1, "freq_ramp": 0.25, "freq_dramp": 0.05,
			"env_attack": 0.1, "env_sustain": 0.4, "env_decay": 0.5, "env_punch": 0.3,
			"vib_strength": 0.3, "vib_speed": 0.5, "pha_offset": 0.4, "pha_ramp": -0.1,
			"lpf_freq": 0.7},
	# --- match flow -----------------------------------------------------------
	"round_start": {"wave_type": SQUARE, "base_freq": 0.45, "env_sustain": 0.15,
			"env_decay": 0.32, "env_punch": 0.2, "hpf_freq": 0.1},
	"fight": {"wave_type": SQUARE, "base_freq": 0.35, "duty": 0.3, "env_sustain": 0.15,
			"env_decay": 0.45, "env_punch": 0.5, "arp_speed": 0.62, "arp_mod": 0.45,
			"vib_strength": 0.05, "vib_speed": 0.5},
	"time_up": {"wave_type": SQUARE, "base_freq": 0.4, "freq_ramp": -0.15, "duty": 0.3,
			"env_sustain": 0.4, "env_decay": 0.4, "repeat_speed": 0.5},
	"timer_tick": {"wave_type": SINE, "base_freq": 0.55, "env_sustain": 0.05,
			"env_decay": 0.18, "hpf_freq": 0.1},
	"match_win": {"wave_type": SQUARE, "base_freq": 0.3, "duty": 0.25, "env_sustain": 0.5,
			"env_decay": 0.6, "env_punch": 0.4, "arp_speed": 0.55, "arp_mod": 0.55,
			"vib_strength": 0.1, "vib_speed": 0.6},
	# --- menus ----------------------------------------------------------------
	"ui_move": {"wave_type": SQUARE, "base_freq": 0.5, "env_sustain": 0.05,
			"env_decay": 0.14, "hpf_freq": 0.15},
	"ui_confirm": {"wave_type": SQUARE, "base_freq": 0.45, "env_sustain": 0.08,
			"env_decay": 0.25, "env_punch": 0.3, "arp_speed": 0.6, "arp_mod": 0.4, "hpf_freq": 0.1},
	"ui_back": {"wave_type": SQUARE, "base_freq": 0.4, "freq_ramp": -0.3,
			"env_sustain": 0.06, "env_decay": 0.2, "hpf_freq": 0.1},
	"pause": {"wave_type": SINE, "base_freq": 0.4, "env_sustain": 0.1, "env_decay": 0.3,
			"arp_speed": 0.65, "arp_mod": -0.4},
}


func _init() -> void:
	var force := "--force" in OS.get_cmdline_user_args()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SFS_DIR))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(WAV_DIR))
	var failed := false
	for name: String in PRESETS:
		var path := SFS_DIR + name + ".sfs"
		if FileAccess.file_exists(path) and not force:
			continue
		var err: Error = SfxrParams.from_dict(PRESETS[name]).save_sfs(path)
		print("write ", path, " -> ", error_string(err))
		failed = failed or err != OK
	for file in DirAccess.get_files_at(SFS_DIR):
		if file.get_extension() == "sfs":
			failed = not _render(file.get_basename()) or failed
	quit(1 if failed else 0)


func _render(name: String) -> bool:
	var params := SfxrParams.new()
	var err := params.load_sfs(SFS_DIR + name + ".sfs")
	if err != OK:
		printerr("bad .sfs ", name, ": ", error_string(err))
		return false
	var samples := SfxrSynth.render(params, hash(name))
	var pk := SfxrSynth.peak(samples)
	var gain := NORMALIZE_PEAK / pk if pk > 0.0 else 1.0
	var path := WAV_DIR + name + ".wav"
	err = SfxrSynth.to_stream(samples, gain).save_to_wav(path)
	print("render %s (%.2fs, peak %.2f) -> %s" % [path, samples.size() / float(SfxrSynth.SAMPLE_RATE), pk, error_string(err)])
	return err == OK
