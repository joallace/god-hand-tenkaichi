class_name UiTuning
extends Resource
## Menu look & feel (data/tuning/ui.tres when present). Read by UiTheme and the
## menu screens in scenes/menus/. Change colors/sizes/timeouts here.

@export_group("Palette")
@export var color_orange: Color = Color(1.0, 0.55, 0.08)
@export var color_orange_light: Color = Color(1.0, 0.78, 0.25)
@export var color_blue: Color = Color(0.10, 0.32, 0.85)
@export var color_blue_dark: Color = Color(0.04, 0.09, 0.28)
@export var color_panel: Color = Color(0.03, 0.06, 0.18, 0.88)
@export var color_text: Color = Color(1.0, 0.98, 0.92)
@export var color_text_dim: Color = Color(0.70, 0.75, 0.90)
@export var color_outline: Color = Color(0.05, 0.02, 0.0)
@export var color_focus: Color = Color(1.0, 0.92, 0.2)
@export var color_disabled: Color = Color(0.35, 0.38, 0.48)
@export var color_p1: Color = Color(1.0, 0.45, 0.1)
@export var color_p2: Color = Color(0.25, 0.65, 1.0)
@export var color_ready: Color = Color(0.35, 1.0, 0.4)

@export_group("Sizes")
@export var font_title: int = 64
@export var font_header: int = 38
@export var font_button: int = 28
@export var font_body: int = 22
@export var font_hint: int = 18
@export var outline_title: int = 16
@export var outline_text: int = 8
@export var font_embolden: float = 0.6
@export var button_min_size: Vector2 = Vector2(460, 52)
@export var corner_radius: int = 6
@export var border_width: int = 4
@export var focus_border_width: int = 6
## Horizontal skew of button/panel boxes (fighting-game slant).
@export var box_skew: float = 0.18
@export var list_separation: int = 10

@export_group("Feel")
## Scale punch on button press.
@export var press_punch_scale: float = 0.92
@export var press_punch_time: float = 0.12
@export var title_pulse_speed: float = 1.6
@export var background_speed: float = 0.25

@export_group("Controls screen")
## Seconds before an unanswered "Press a button..." prompt cancels.
@export var rebind_timeout_seconds: float = 5.0
## Minimum seconds after entering listening before input is accepted
## (plus the confirm press must have been released).
@export var rebind_arm_delay: float = 0.15

@export_group("Join screen")
## Seconds between "all ready" and the match starting (cancel by un-readying).
@export var join_start_delay: float = 1.0
## Stick deflection that counts as a menu direction on the join screen.
@export var stick_nav_threshold: float = 0.6
