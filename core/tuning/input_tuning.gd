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
## Forward dash = forward (toward the target) tapped twice: the second tap
## must start within this many frames of the first.
@export_range(1, 60) var dash_tap_window_frames: int = 14
## Left stick / keys toward the target past this count as a forward tap.
@export_range(0.1, 1.0) var dash_tap_threshold: float = 0.6
## Forward must fall back under this between the two taps.
@export_range(0.0, 0.9) var dash_tap_rearm: float = 0.3
## Frames an input press stays buffered for the fighter state machine.
@export_range(0, 20) var input_buffer_frames: int = 6
