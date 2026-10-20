extends Node
## Autoload "Tuning": the single place gameplay reads constants from.
## Each resource loads from data/tuning/<key>.tres when present, otherwise the
## script defaults are used. Regenerate the .tres files with:
##   godot --headless --script res://tools/generate_tuning.gd
## Add new tuning categories by adding a var + an entry in REGISTRY.

const DIR := "res://data/tuning/"

## property name -> script that defines it
const REGISTRY := {
	"input": preload("res://core/tuning/input_tuning.gd"),
	"match_rules": preload("res://core/tuning/match_tuning.gd"),
	"fighter": preload("res://core/tuning/fighter_tuning.gd"),
	"ui": preload("res://core/tuning/ui_tuning.gd"),
	"camera": preload("res://core/tuning/camera_tuning.gd"),
	"hud": preload("res://core/tuning/hud_tuning.gd"),
	"vfx": preload("res://core/tuning/vfx_tuning.gd"),
	"arena": preload("res://core/tuning/arena_tuning.gd"),
	"sfx": preload("res://core/tuning/sfx_tuning.gd"),
	"cpu": preload("res://core/tuning/cpu_tuning.gd"),
	"targeting": preload("res://core/tuning/targeting_tuning.gd"),
	"coop": preload("res://core/tuning/coop_tuning.gd"),
	"net": preload("res://core/tuning/net_tuning.gd"),
	"video": preload("res://core/tuning/video_tuning.gd"),
}

var input: InputTuning
var match_rules: MatchTuning
var fighter: FighterTuning
var ui: UiTuning
var camera: CameraTuning
var hud: HudTuning
var vfx: VfxTuning
var arena: ArenaTuning
var sfx: SfxTuning
var cpu: CpuTuning
var targeting: TargetingTuning
var coop: CoopTuning
var net: NetTuning
var video: VideoTuning


func _init() -> void:
	reload()


func reload() -> void:
	for key in REGISTRY:
		set(key, load_or_default(key, REGISTRY[key]))


static func load_or_default(key: String, script: Script) -> Resource:
	var path: String = DIR + key + ".tres"
	if ResourceLoader.exists(path):
		var r := load(path)
		if r != null and r.get_script() == script:
			return r
	return script.new()
