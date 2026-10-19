class_name TickInput
extends InputSource
## Test input: a pseudo-random frame that is a pure function of (seed, tick),
## so re-simulating a tick after a rollback, or a source rebuilt mid-match,
## produces the same frame. Exercises every frame field (moves, buttons
## including PAUSE every `pause_every` ticks, dodges, target requests).

var seed_value: int = 0
## 0 = never press PAUSE.
var pause_every: int = 0


func _init(p_seed: int = 0, p_pause_every: int = 0) -> void:
	seed_value = p_seed
	pause_every = p_pause_every


func _sample(tick: int) -> InputFrame:
	var h := hash([seed_value, tick / 6])  # hold each choice for 6 ticks
	var f := InputFrame.new()
	f.move_x = (h & 0xFF) % 255 - 127
	f.move_y = ((h >> 8) & 0xFF) % 255 - 127
	f.held = (h >> 16) & 0x1FF & ~InputFrame.Btn.PAUSE
	if tick % 6 == 0:
		f.dodge = ((h >> 25) % 5) as InputFrame.Dodge
	f.target_request = -1 if (h >> 28) & 1 == 0 else 1
	if pause_every > 0 and tick % pause_every == 0:
		f.held |= InputFrame.Btn.PAUSE
	return f
