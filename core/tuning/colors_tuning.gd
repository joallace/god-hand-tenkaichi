class_name ColorsTuning
extends Resource
## The colours that tell fighters apart: body, ki and beams, and their name on
## the HUD, lobby and results. Edit data/tuning/colors.tres.

## What players pick from in the lobby (MatchConfig slots keep an index).
## The first entries are the slot defaults: P1, P2, P3, P4.
@export var palette: PackedColorArray = PackedColorArray([
	Color(1.0, 0.55, 0.1),
	Color(0.2, 0.6, 1.0),
	Color(0.8, 0.45, 1.0),
	Color(0.3, 0.95, 0.75),
	Color(1.0, 0.9, 0.2),
	Color(1.0, 0.45, 0.75),
	Color(0.95, 0.95, 0.95),
	Color(0.55, 0.9, 0.25),
])
## Shown in the lobby; same order as `palette`.
@export var names: PackedStringArray = PackedStringArray([
	"Orange", "Blue", "Purple", "Teal", "Yellow", "Pink", "White", "Lime",
])
## Every co-op enemy. Keep it apart from `palette`: anything that isn't this
## colour is on your side.
@export var enemy_color: Color = Color(0.72, 0.1, 0.14)


func count() -> int:
	return palette.size()


## Palette entry `index`; out of range wraps.
func color(index: int) -> Color:
	return palette[posmod(index, palette.size())]


func color_name(index: int) -> String:
	return names[posmod(index, names.size())]
