class_name BeachArenaTuning
extends ArenaTuning
## The beach bar stage (presentation only, like ArenaTuning, whose sky and
## light values it overrides in _init): late afternoon on the orla of João
## Pessoa. Bar and tables on the -Z side, sea and umbrellas on the +Z side.
## Every gap is measured from the play radius, so the layout follows co-op's
## bigger arenas. Keep gaps that hold something tall beyond
## Tuning.camera.radius_margin, or the camera walks through it.
## Edit data/tuning/arena_beach.tres.

@export_group("Layout")
## Distance from the play circle to the waterline at x = 0.
@export var shore_gap: float = 18.0
## Curve of the bay: the waterline moves shore_bend * x * |x| toward the land
## on +X (the city's side) and toward the sea on -X (the headland's side).
@export var shore_bend: float = 0.0011
## Distance from the play circle to the bar's rear wall.
@export var bar_gap: float = 11.0
@export var bar_width: float = 20.0
@export var bar_depth: float = 7.0
## Distance from the play circle to where the sand gives way to grass.
@export var grass_gap: float = 26.0
## How far the grass runs before the promenade.
@export var grass_depth: float = 12.0
@export var promenade_width: float = 9.0
@export var rope_height: float = 0.75
@export var rope_stake_spacing: float = 3.2

@export_group("Tables")
## One arc of tables per entry, at this distance from the play circle.
@export var table_row_gaps: PackedFloat32Array = PackedFloat32Array([2.4, 5.6])
@export var table_spacing: float = 4.2
## Angle covered by the table arcs, centred on the bar.
@export var table_arc_deg: float = 92.0
## Chance for a seat to be empty of its chair, and for a chair to be knocked
## over (a fight is going on).
@export_range(0.0, 1.0) var chair_missing_chance: float = 0.15
@export_range(0.0, 1.0) var chair_toppled_chance: float = 0.1

@export_group("Umbrellas")
@export var umbrella_row_gaps: PackedFloat32Array = PackedFloat32Array([10.0, 13.0])
@export var umbrella_spacing: float = 6.5
@export var umbrella_arc_deg: float = 120.0
@export var umbrella_colors: PackedColorArray = PackedColorArray([
	Color(0.84, 0.13, 0.12), Color(0.84, 0.13, 0.12), Color(0.95, 0.74, 0.1), Color(0.1, 0.36, 0.7),
])

@export_group("Brands")
## Plastic furniture and signs, alternating. Wordmarks only.
@export var brand_a_name: String = "SKOL"
@export var brand_a_color: Color = Color(0.95, 0.68, 0.02)
@export var brand_a_text_color: Color = Color(0.8, 0.07, 0.08)
@export var brand_b_name: String = "ANTARCTICA"
@export var brand_b_color: Color = Color(0.06, 0.2, 0.52)
@export var brand_b_text_color: Color = Color(0.98, 0.98, 0.98)
@export var bar_sign: String = "BAR DA ORLA"

@export_group("Colors")
@export var sand_light: Color = Color(0.86, 0.73, 0.55)
@export var sand_dark: Color = Color(0.71, 0.57, 0.41)
@export var sand_wet: Color = Color(0.5, 0.42, 0.33)
@export var grass_color: Color = Color(0.29, 0.43, 0.16)
@export var promenade_color: Color = Color(0.62, 0.56, 0.52)
@export var water_shallow: Color = Color(0.3, 0.6, 0.48)
@export var water_deep: Color = Color(0.05, 0.3, 0.36)
## Late sun on the water, strongest far out.
@export var water_glint: Color = Color(0.95, 0.76, 0.42)
@export var foam_color: Color = Color(0.97, 0.95, 0.88)
@export var wall_paint: Color = Color(0.26, 0.6, 0.6)
@export var wall_trim: Color = Color(0.93, 0.9, 0.82)
@export var thatch_color: Color = Color(0.62, 0.48, 0.27)
@export var wood_color: Color = Color(0.42, 0.29, 0.18)
@export var rope_color: Color = Color(0.84, 0.74, 0.52)
@export var chair_white: Color = Color(0.94, 0.94, 0.91)
@export var trunk_color: Color = Color(0.5, 0.41, 0.31)
@export var frond_color: Color = Color(0.24, 0.45, 0.14)
@export var tower_colors: PackedColorArray = PackedColorArray([
	Color(0.74, 0.72, 0.68), Color(0.7, 0.66, 0.58), Color(0.6, 0.6, 0.6),
	Color(0.72, 0.58, 0.48), Color(0.5, 0.56, 0.62),
])
@export var headland_color: Color = Color(0.32, 0.42, 0.28)

@export_group("Sea motion")
@export var swash_reach: float = 2.6
@export var swash_speed: float = 0.55
@export var wet_width: float = 3.5
@export var breaker_spacing: float = 17.0
@export var breaker_speed: float = 0.05

@export_group("Skyline")
@export var palm_count: int = 34
## Along the coast, from x = 0 (+X and -X).
@export var palm_span: float = 170.0
@export var tower_count: int = 150
## Distance from the far side of the road to the first and last buildings.
@export var tower_min_inland: float = 45.0
@export var tower_max_inland: float = 290.0
## Along the coast, from x = 0 (+X and -X).
@export var tower_span: float = 460.0
## Height next to the seafront and at tower_max_inland: the city steps up
## away from the beach.
@export var tower_height_front: float = 10.0
@export var tower_height_back: float = 72.0
@export var headland_x: float = -340.0

@export_group("Renderer")
## Sun and ambient multiplier on the Compatibility renderer (the web build),
## which lights this bright stage far hotter than Forward+.
@export var compatibility_light_scale: float = 0.62

@export_group("Clouds")
@export var cloud_lit: Color = Color(1.0, 0.95, 0.84)
@export var cloud_shade: Color = Color(0.72, 0.6, 0.5)
@export_range(0.0, 1.0) var cloud_cover: float = 0.56
@export var cloud_scale: float = 2.6
@export var sun_glow: Color = Color(1.0, 0.72, 0.38)


func _init() -> void:
	sky_top_color = Color(0.1, 0.45, 0.68)
	sky_horizon_color = Color(0.96, 0.8, 0.58)
	sun_energy = 1.05
	sun_pitch_deg = -30.0
	# Along the coast and a little from the sea: the sun really sets behind
	# the city, but that would leave the bar's wall and its signs unlit.
	sun_yaw_deg = 72.0
	ambient_energy = 0.5
	tonemap_mode = Environment.TONE_MAPPER_ACES
	tonemap_exposure = 0.85
	# The bright sand would bloom into a veil over the whole frame.
	glow_enabled = false
	shadow_max_distance = 70.0
	fog_density = 0.0028
	outer_ground_size = 1000.0
