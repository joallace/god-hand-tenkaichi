class_name ReplayRecorder
extends Node
## Records a MatchDirector into a Replay (SPEC_ONLINE.md §11): human slots'
## polled frames (inputs_polled; a re-simulated tick overwrites, so the
## rollback-corrected input wins), a StateHash every
## Tuning.net.replay_hash_interval ticks and at the end, the command log and
## end_tick. CPU slots aren't recorded: playback re-runs their brains.
##
## The match scene adds one per match: it auto-keeps the replay
## (Replay.save_auto) when the match ends and again (same file) when it
## leaves the tree, so a quit mid-match is kept too. Headless runs (tests,
## tools) don't auto-keep unless `auto_save_headless`.

## Write user://replays/last_<n>.ghr on match end / exit.
var auto_save := true
static var auto_save_headless := false

var replay: Replay
var director: MatchDirector
## Path of this recorder's auto-kept file ("" until first written).
var auto_path: String = ""

var _recorded: Dictionary = {}  # slot -> true for slots whose frames are kept
var _saved_tick := -1
var _save_pending := false


## Start recording `d` (after d.setup(): needs its config).
func attach(d: MatchDirector) -> void:
	director = d
	replay = Replay.create(d.config)
	_recorded.clear()
	for p in d.config.players:
		if p.input_kind != PlayerSlotConfig.InputKind.CPU:
			_recorded[p.slot] = true
	d.inputs_polled.connect(_on_inputs_polled)
	d.tick_completed.connect(_on_tick_completed)
	d.match_ended.connect(_on_match_ended)


## The replay so far, completed (commands, end hash, trimmed).
func finish() -> Replay:
	if is_instance_valid(director):
		replay.end_tick = director.tick
		replay.commands = director.commands()
		# Out of the tree (scene exiting) node transforms can't be read.
		if director.is_inside_tree() and director.tick > 0:
			replay.hashes[director.tick] = StateHash.of(director)
	replay.trim()
	return replay


## Auto-keep now (overwrites this recorder's earlier auto file). Returns
## the path or "".
func save_auto(dir: String = Replay.AUTO_DIR) -> String:
	finish()
	if auto_path != "":
		auto_path = auto_path if replay.save(auto_path) == OK else ""
	else:
		auto_path = replay.save_auto(dir)
	_saved_tick = replay.end_tick
	return auto_path


func _on_inputs_polled(tick: int, slots: PackedInt32Array, frames: Array[InputFrame]) -> void:
	for i in slots.size():
		if _recorded.has(slots[i]):
			replay.set_frame(slots[i], tick, frames[i])


func _on_tick_completed(tick: int) -> void:
	replay.end_tick = tick
	if tick % Tuning.net.replay_hash_interval == 0:
		replay.hashes[tick] = StateHash.of(director)
	if _save_pending:
		_save_pending = false
		save_auto()


## match_ended fires mid-step: save once the tick is complete.
func _on_match_ended(_winner_slot: int) -> void:
	if _auto_enabled():
		_save_pending = true


func _exit_tree() -> void:
	if _auto_enabled() and replay != null and replay.end_tick > 0 and replay.end_tick != _saved_tick:
		save_auto()


func _auto_enabled() -> bool:
	return auto_save and (auto_save_headless or DisplayServer.get_name() != "headless")
