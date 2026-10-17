extends Node
## Autoload "Game": app-level flow and the hand-off between menus and match.

const SCENE_MAIN_MENU := "res://scenes/menus/main_menu.tscn"
const SCENE_JOIN := "res://scenes/menus/join_screen.tscn"
const SCENE_CONTROLS := "res://scenes/menus/controls_screen.tscn"
const SCENE_MATCH := "res://scenes/match/match.tscn"
const SCENE_RESULTS := "res://scenes/menus/results_screen.tscn"

## Config for the match about to start / in progress.
var current_config: MatchConfig
## Filled when a match ends: {"winner_slot": int, "wins": PackedInt32Array, "config": MatchConfig}
var last_result: Dictionary = {}


func start_match(config: MatchConfig) -> void:
	current_config = config
	goto(SCENE_MATCH)


func finish_match(winner_slot: int, wins: PackedInt32Array) -> void:
	last_result = {"winner_slot": winner_slot, "wins": wins, "config": current_config}
	goto(SCENE_RESULTS)


func goto(path: String) -> void:
	get_tree().paused = false
	get_tree().change_scene_to_file.call_deferred(path)
