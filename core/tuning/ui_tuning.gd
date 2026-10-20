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

@export_group("Layout")
## Vertical gap between the main menu's title, subtitle, buttons and hint.
@export var main_menu_separation: int = 10
## How-to-play overlay: space kept free around the panel (x: sides, y: top/bottom).
@export var how_to_margin: Vector2 = Vector2(48, 20)
## How-to-play grid gaps (x: between columns, y: between rows).
@export var how_to_grid_separation: Vector2i = Vector2i(40, 6)
## Pixels scrolled per ui_up / ui_down press (held keys repeat).
@export var how_to_scroll_step: float = 64.0
## Right-stick scroll speed (pixels per second at full deflection).
@export var how_to_stick_scroll_speed: float = 900.0
## Right-stick deflection below which the how-to-play list doesn't scroll.
@export var how_to_stick_deadzone: float = 0.3

@export_group("Join screen")
## Space kept free around the join screen (x: sides, y: top/bottom).
@export var join_margin: Vector2 = Vector2(24, 12)
## Gap between the title, the panels row, the status and the hint lines.
@export var join_root_separation: int = 4
## Gap between the player panels and the shared settings panel.
@export var join_column_separation: int = 16
## The screen title is smaller than other titles so the rows fit 648 px.
@export var join_title_font: int = 44
## Player panel: "CHOOSE!" / "READY!" state line and the fighter name.
@export var join_state_font: int = 30
@export var join_character_font: int = 26
## Shared settings rows (match rules / co-op run) font and row gap.
@export var join_row_font: int = 20
@export var join_row_separation: int = 2
## Settings panel width relative to one player panel (both expand).
@export var join_settings_ratio: float = 1.5
## Border width of the P1/P2-coloured player panels.
@export var join_panel_border: int = 6
## Seconds between "all ready" and the match starting (cancel by un-readying).
@export var join_start_delay: float = 1.0
## Stick deflection that counts as a menu direction on the join screen.
@export var stick_nav_threshold: float = 0.6

@export_group("Results screen")
## Vertical gap between the headline, tally and button list (versus).
@export var results_separation: int = 30
## Tighter gap used by the co-op layout (headline, team line, table, buttons).
@export var results_coop_separation: int = 8
## Headline scale pulse: amplitude (fraction of size) and speed (rad/s).
@export var results_pulse_amount: float = 0.04
@export var results_pulse_speed: float = 4.0
## Co-op stats table: min width of the row-label column / each player column,
## gaps between cells, and the tallest it may get before it scrolls.
@export var results_label_col_width: int = 230
@export var results_player_col_width: int = 190
@export var results_table_h_gap: int = 18
@export var results_table_v_gap: int = 0
@export var results_table_max_height: int = 260
## Inner padding of the stats panel.
@export var results_panel_padding: int = 10

@export_group("Online screens")
## Settings and join-online screens: gap between the title, rows and footer.
@export var online_separation: int = 14
## Width of the text fields (profile name, port, address).
@export var online_field_width: int = 420
## Label column width on the settings screen's text-field rows.
@export var online_label_width: int = 220
## Recent hosts list: tallest it gets before it scrolls, row height, and the
## size of each row's delete ("x") button.
@export var online_recent_max_height: int = 260
@export var online_recent_row_height: int = 46
@export var online_delete_button_size: Vector2 = Vector2(56, 46)
## Status / error line colours.
@export var color_error: Color = Color(1.0, 0.4, 0.35)
@export var color_ok: Color = Color(0.35, 1.0, 0.4)

@export_group("Settings screen")
## Gap between the title, tab bar, page and footer; outer margin (x, y).
@export var settings_separation: int = 8
@export var settings_margin: Vector2 = Vector2(80, 16)
## Tab bar: gap between tabs, tab font size.
@export var settings_tab_separation: int = 28
@export var settings_tab_font: int = 30
## Width of the option rows on the Graphics / Audio / Online pages.
@export var settings_row_width: int = 640
## Number steppers: held repeats before the fast step kicks in.
@export var stepper_fast_after_repeats: int = 6
## Host port stepper: fast (held) step.
@export var port_step_fast: int = 100
## Confirm prompts (reset, keep display settings): panel padding and width.
@export var confirm_padding: int = 28
@export var confirm_width: int = 620
