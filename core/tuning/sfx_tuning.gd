class_name SfxTuning
extends Resource
## Sound effects mix (presentation only). Edit data/tuning/sfx.tres.
## Sounds themselves are sfxr files: data/sfx/*.sfs -> assets/sfx/*.wav via
## tools/generate_sfx.gd. Volumes in dB, times in seconds.

@export_group("Mix")
@export var enabled: bool = true
## Bus for gameplay sounds; menu sounds (ui_sounds) go to ui_bus. Both feed
## Master. The player's volumes per bus live in user://audio.cfg
## (AudioSettings); the buses are in res://default_bus_layout.tres.
@export var bus: StringName = &"SFX"
@export var ui_bus: StringName = &"UI"
## Sounds routed to ui_bus: names starting with ui_sound_prefix plus these.
@export var ui_sound_prefix: String = "ui_"
@export var ui_sounds: Array[StringName] = [&"pause"]
@export var master_volume_db: float = -6.0
## Per-sound offset added to master_volume_db (sound name -> dB). Unlisted
## sounds play at 0 dB offset.
@export var volume_db: Dictionary[StringName, float] = {
	&"hit_light": 0.0,
	&"hit_heavy": 1.0,
	&"hit_block": -3.0,
	&"ki_guard": -3.0,
	&"push_off": -2.0,
	&"throw": -2.0,
	&"taunt": -5.0,
	&"taunt_done": -4.0,
	&"ground_bounce": 0.0,
	&"swing_light": -9.0,
	&"swing_heavy": -7.0,
	&"dodge": -6.0,
	&"dash": -8.0,
	&"jump": -8.0,
	&"ki_charge_loop": -10.0,
	&"ki_charge_start": -4.0,
	&"beam_fire": -2.0,
	&"ko": 2.0,
	&"timer_tick": -6.0,
	&"ui_move": -8.0,
	&"ui_confirm": -4.0,
	&"ui_back": -5.0,
}
## Simultaneous one-shot voices; the oldest is cut when all are busy.
@export var voices: int = 16

@export_group("Player volume")
## Settings > Audio sliders: default and step, in percent (0 = muted).
@export var default_volume_percent: int = 100
@export var volume_step_percent: int = 5

@export_group("Variation")
## Random +- pitch scale on gameplay one-shots so repeats don't sound robotic.
@export var pitch_jitter: float = 0.05
## Hit pitch rises this much per combo hit, up to combo_pitch_max.
@export var combo_pitch_step: float = 0.015
@export var combo_pitch_max: float = 0.25

@export_group("Loops")
@export var loop_fade_out: float = 0.12

@export_group("Timer")
## Tick each second while the round timer is at or below this (0 = never).
@export var timer_warning_seconds: int = 5
