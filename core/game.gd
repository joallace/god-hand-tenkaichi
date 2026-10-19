extends Node
## Autoload "Game": app-level flow and the hand-off between menus and match.

const SCENE_MAIN_MENU := "res://scenes/menus/main_menu.tscn"
const SCENE_LOBBY := "res://scenes/menus/lobby.tscn"
const SCENE_JOIN_ONLINE := "res://scenes/menus/join_online_screen.tscn"
const SCENE_SETTINGS := "res://scenes/menus/settings_screen.tscn"
const SCENE_CONTROLS := "res://scenes/menus/controls_screen.tscn"
const SCENE_MATCH := "res://scenes/match/match.tscn"
const SCENE_RESULTS := "res://scenes/menus/results_screen.tscn"

## Config for the match about to start / in progress.
var current_config: MatchConfig
## Filled when a match ends: {"winner_slot": int, "wins": PackedInt32Array, "config": MatchConfig}
## plus, after a co-op run, RunStats.result(): "stats" (team-0 slot -> per-
## player counters) and "run" (cleared, frames, seconds, waves_cleared).
var last_result: Dictionary = {}


func start_match(config: MatchConfig) -> void:
	current_config = config
	goto(SCENE_MATCH)


## Start the current match/run over with the same config (pause menu
## "Restart run", results "Retry"). Does nothing without a config.
func restart_match() -> void:
	if current_config != null:
		start_match(current_config)


func finish_match(winner_slot: int, wins: PackedInt32Array, extra: Dictionary = {}) -> void:
	last_result = {"winner_slot": winner_slot, "wins": wins, "config": current_config}
	for k: Variant in extra:
		if not last_result.has(k):
			last_result[k] = extra[k]
	goto(SCENE_RESULTS)


func goto(path: String) -> void:
	get_tree().paused = false
	get_tree().change_scene_to_file.call_deferred(path)
