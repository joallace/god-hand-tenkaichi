class_name HudTuning
extends Resource
## Match HUD look & timings (presentation only). Edit data/tuning/hud.tres.
## Sizes are in canvas pixels of the base viewport (stretch mode scales them).

@export_group("Fonts")
@export var font_names: PackedStringArray = PackedStringArray(["Impact", "Anton", "Arial Black", "DejaVu Sans", "sans-serif"])
@export var font_weight: int = 900
@export var name_font_size: int = 22
@export var timer_font_size: int = 40
@export var combo_font_size: int = 40
## Per-player callouts (GUARD CRASH / THROW BREAK / COUNTER) under the combo.
@export var callout_font_size: int = 30
@export var announce_font_size: int = 96
@export var outline_size: int = 8

@export_group("Layout")
@export var top_margin: float = 14.0
@export var side_margin: float = 18.0
## Gap between the two health bars, where the timer sits.
@export var center_gap: float = 110.0
@export var health_bar_height: float = 24.0
@export var ki_bar_height: float = 12.0
## Ki gauge width as a fraction of the health bar width.
@export_range(0.2, 1.0) var ki_width_ratio: float = 0.62
@export var ki_segment_gap: float = 4.0
## Slant of the bar ends (px) for a dynamic look.
@export var bar_skew: float = 10.0
@export var pip_size: float = 12.0
@export var divider_width: float = 4.0

@export_group("Colors")
@export var p1_color: Color = Color(1.0, 0.55, 0.1)
@export var p2_color: Color = Color(0.2, 0.6, 1.0)
@export var bar_bg_color: Color = Color(0.05, 0.05, 0.08, 0.85)
@export var bar_border_color: Color = Color(1, 1, 1, 0.9)
@export var health_high_color: Color = Color(1.0, 0.85, 0.15)
@export var health_low_color: Color = Color(1.0, 0.2, 0.1)
@export var health_trail_color: Color = Color(0.9, 0.1, 0.1)
@export var ki_full_color: Color = Color(0.35, 0.95, 1.0)
@export var ki_partial_color: Color = Color(0.15, 0.45, 0.7)
@export var ki_empty_color: Color = Color(0.05, 0.1, 0.15, 0.85)
@export var ki_denied_color: Color = Color(1.0, 0.15, 0.15)
@export var pip_empty_color: Color = Color(0.2, 0.2, 0.2, 0.8)
@export var pip_won_color: Color = Color(1.0, 0.9, 0.2)
@export var text_color: Color = Color(1, 1, 1)
@export var outline_color: Color = Color(0.05, 0.02, 0.0)
@export var announce_color: Color = Color(1.0, 0.92, 0.3)
@export var ko_color: Color = Color(1.0, 0.25, 0.15)
@export var divider_color: Color = Color(0, 0, 0)
@export var pause_dim_color: Color = Color(0, 0, 0, 0.6)
@export var guard_crash_color: Color = Color(1.0, 0.45, 0.1)
@export var throw_break_color: Color = Color(0.85, 0.95, 1.0)
@export var counter_color: Color = Color(1.0, 0.95, 0.4)

@export_group("Timings (seconds)")
@export var health_trail_delay: float = 0.5
## Trail drain speed in health ratio per second.
@export var health_trail_speed: float = 0.7
@export var ki_denied_flash: float = 0.4
@export var combo_min_hits: int = 2
@export var combo_linger: float = 1.2
@export var callout_hold: float = 0.9
@export var callout_fade: float = 0.25
@export var announce_in: float = 0.18
@export var announce_hold: float = 1.0
@export var announce_out: float = 0.25
## Delay between "K.O." and "P1 WINS".
@export var round_result_delay: float = 1.1
## Delay between match end and the results screen.
@export var match_end_delay: float = 3.5

@export_group("Texts")
@export var text_round: String = "ROUND %d"
@export var text_final_round: String = "FINAL ROUND"
@export var text_fight: String = "FIGHT!"
@export var text_ko: String = "K.O."
@export var text_time: String = "TIME"
@export var text_draw: String = "DRAW"
@export var text_round_winner: String = "P%d WINS"
@export var text_match_winner: String = "P%d VICTORY!"
@export var text_combo: String = "%d HITS"
@export var text_infinite: String = "∞"
@export var text_guard_crash: String = "GUARD CRASH"
@export var text_throw_break: String = "THROW BREAK"
@export var text_counter: String = "COUNTER!"

@export_group("Co-op (per-view HUD)")
## Current target's bar: centered in each view, this far below its top edge.
@export var coop_target_top: float = 104.0
@export var coop_target_width: float = 360.0
@export var coop_target_bar_height: float = 16.0
@export var coop_target_ki_height: float = 8.0
@export var coop_small_font_size: int = 18
## Teammate panels, stacked from the view's bottom-left corner.
@export var coop_partner_width: float = 200.0
@export var coop_partner_bar_height: float = 10.0
@export var coop_partner_ki_height: float = 6.0
@export var coop_partner_margin: float = 16.0
@export var coop_partner_spacing: float = 52.0
## World-space HP pips over enemies (m above the feet, px size).
@export var pip_world_height: float = 2.25
@export var enemy_pip_width: float = 54.0
@export var enemy_pip_height: float = 6.0
@export var enemy_pip_bg_color: Color = Color(0.05, 0.05, 0.08, 0.8)
@export var enemy_pip_color: Color = Color(1.0, 0.3, 0.2)
## The pip of this view's current target.
@export var enemy_pip_target_color: Color = Color(1.0, 0.85, 0.2)
## Screen-edge arrows for off-screen enemies.
@export var edge_arrow_size: float = 16.0
@export var edge_arrow_inset: float = 28.0
@export var edge_arrow_color: Color = Color(1.0, 0.35, 0.25, 0.9)
## Revive ring over a downed teammate (m above the feet, px).
@export var revive_marker_height: float = 1.2
@export var revive_ring_radius: float = 26.0
@export var revive_ring_width: float = 5.0
@export var revive_ring_bg_color: Color = Color(0.0, 0.0, 0.0, 0.55)
@export var revive_ring_color: Color = Color(0.4, 1.0, 0.5)
@export var revive_arc_points: int = 32
@export var downed_color: Color = Color(1.0, 0.55, 0.2)
@export var out_color: Color = Color(0.55, 0.55, 0.6)
## "P1 ULTIMATE" banner on the other views.
@export var banner_font_size: int = 40
## Vertical position as a fraction of the view height.
@export_range(0.0, 1.0) var banner_y_ratio: float = 0.3
@export var banner_hold: float = 1.2
@export var banner_color: Color = Color(1.0, 0.9, 0.3)
@export var enemies_left_font_size: int = 24

@export_group("Co-op texts")
@export var text_downed: String = "DOWNED"
@export var text_out: String = "OUT"
## Seconds left before a downed teammate bleeds out.
@export var text_bleed_out: String = "%d"
@export var text_ultimate_banner: String = "%s ULTIMATE"
## Tag for enemy fighters (they have no player slot config).
@export var text_enemy_tag: String = "ENEMY"
@export var text_enemies_left: String = "ENEMIES  %d"
@export var text_run_cleared: String = "CLEARED!"
@export var text_run_failed: String = "WIPED OUT"
## Waves: announcer on a wave's entry / clear, and the counter under the timer.
@export var text_wave: String = "WAVE %d"
@export var text_final_wave: String = "FINAL WAVE"
@export var text_wave_clear: String = "WAVE CLEAR!"
@export var text_wave_counter: String = "WAVE  %d / %d"
@export var text_wave_counter_endless: String = "WAVE  %d"

@export_group("Online")
## "⏸ <name>" tag on a player's panel while that peer has the pause overlay open.
@export var pause_tag_font_size: int = 18
@export var pause_tag_color: Color = Color(1.0, 1.0, 1.0, 0.9)
@export var text_pause_tag: String = "⏸ %s"
## "Waiting for <name>…" while the sim is stalled on a peer.
@export var waiting_font_size: int = 32
@export var waiting_color: Color = Color(1.0, 0.92, 0.3)
## Vertical position of the waiting banner (fraction of the screen height);
## notices ("<name> disconnected") go right under it.
@export_range(0.0, 1.0) var waiting_y_ratio: float = 0.22
@export var text_waiting_for: String = "Waiting for %s…"
@export var notice_font_size: int = 26
@export var notice_color: Color = Color(1.0, 0.55, 0.4)
@export var notice_hold: float = 2.5
@export var text_disconnected: String = "%s disconnected"
## Winner announcements online (player names instead of P1 / P2).
@export var text_round_winner_name: String = "%s WINS"
@export var text_match_winner_name: String = "%s VICTORY!"
## Pause overlay subtitle online (the sim keeps running).
@export var text_online_paused: String = "%s paused · the match goes on"

@export_group("Net overlay (debug)")
@export var net_overlay_font_size: int = 14
@export var net_overlay_margin: float = 10.0
@export var net_overlay_padding: float = 6.0
@export var net_overlay_color: Color = Color(0.75, 1.0, 0.75)
@export var net_overlay_bg_color: Color = Color(0.0, 0.0, 0.0, 0.6)
## Window (s) for the rollbacks-per-second rate.
@export var net_overlay_rate_window: float = 1.0
