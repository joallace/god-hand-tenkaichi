class_name MatchEventHub
extends Node
## Funnels both fighters' `event` signals into one deduplicated stream for the
## presentation layer (cameras, VFX, HUD). Also remembers each fighter's
## position at the start of the physics frame so effects like teleport can
## flash at the old location even if the event payload omits it.

signal fighter_event(fighter: Fighter, kind: StringName, data: Dictionary)

var fighters: Array[Fighter] = []
var _last_pos: Dictionary = {}  # Fighter -> Vector3 (start of physics frame)
var _seen: Dictionary = {}  # dedup keys for the current physics frame
var _seen_frame := -1


func _init() -> void:
	name = "MatchEventHub"
	# Run before the MatchDirector ticks so _last_pos is the pre-tick position.
	process_physics_priority = -100


func watch(p_fighters: Array[Fighter]) -> void:
	fighters = p_fighters
	for f in fighters:
		_last_pos[f] = f.global_position
		f.event.connect(_on_event.bind(f))


func last_position(f: Fighter) -> Vector3:
	return _last_pos.get(f, f.global_position)


func _physics_process(_delta: float) -> void:
	for f in fighters:
		if is_instance_valid(f):
			_last_pos[f] = f.global_position


func _on_event(kind: StringName, data: Dictionary, f: Fighter) -> void:
	# The same hit may be reported by attacker and victim; show it once.
	var frame := Engine.get_physics_frames()
	if frame != _seen_frame:
		_seen_frame = frame
		_seen.clear()
	if kind == &"hit":
		var key := "%s|%s|%s" % [data.get("attacker_slot", -1), data.get("position", Vector3.INF), data.get("damage", 0)]
		if _seen.has(key):
			return
		_seen[key] = true
	fighter_event.emit(f, kind, data)


## Fighter that receives the hit described by a &"hit" event emitted by `f`.
func hit_victim(f: Fighter, data: Dictionary) -> Fighter:
	var attacker_slot: int = data.get("attacker_slot", -1)
	if attacker_slot == f.slot and f.target != null:
		return f.target
	return f


## World position for an event: payload `position` if present, else fighter.
func event_position(f: Fighter, data: Dictionary, height: float) -> Vector3:
	var p: Variant = data.get("position")
	if p is Vector3:
		return p
	return f.global_position + Vector3.UP * height
