class_name InputTuning
extends Resource
## Device feel. Edit data/tuning/input.tres in the inspector.

@export_range(0.0, 0.9) var stick_deadzone: float = 0.2
## Right stick magnitude that fires a dodge flick.
@export_range(0.1, 1.0) var flick_threshold: float = 0.75
## Right stick must fall below this before another flick can fire.
@export_range(0.0, 0.9) var flick_rearm: float = 0.35
## Analog trigger value that counts as "pressed".
@export_range(0.05, 1.0) var trigger_threshold: float = 0.5
## Frames an input press stays buffered for the fighter state machine.
@export_range(0, 20) var input_buffer_frames: int = 6
