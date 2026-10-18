class_name CpuInput
extends InputSource
## P1 vs CPU: a CpuBrain reads the match via the attached MatchDirector and
## emits InputFrames like a human would, so the fighter code needs no
## AI-specific branches. `level` indexes Tuning.cpu.level_names.

var brain: CpuBrain


func _init(level: int = -1) -> void:
	brain = CpuBrain.new(level)


func attach(context: Node, slot: int) -> void:
	var director := context as MatchDirector
	# Seeded per match + slot: CPU vs CPU replays the same fight.
	brain.rng.seed = hash([director.config.rng_seed if director and director.config else 0, slot])
	brain.attach(director, slot)


func _sample(_tick: int) -> InputFrame:
	return brain.think()


## The brain only advances when polled; nothing to re-read after a pause.
func resync(_tick: int) -> void:
	pass


func reset() -> void:
	super.reset()
	brain.reset()


func save_state() -> Dictionary:
	var s := super.save_state()
	s["brain"] = brain.save_state()
	return s


func load_state(s: Dictionary) -> void:
	super.load_state(s)
	brain.load_state(s["brain"])
