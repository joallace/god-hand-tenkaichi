class_name Arena
extends Node3D
## Stylized circular arena: tiled stone floor of radius `radius` (set it to
## MatchDirector.arena_radius_for(config) before adding; 0 =
## Tuning.match_rules.arena_radius), rocky ring edge, translucent energy wall at
## the boundary, boulders/pillars outside the ring, distant mountains, a bright
## procedural sky and a shadowed sun. Visual only, plus a flat static floor
## collider (top at y = 0) for any physics-based movement.
## Look is driven by Tuning.arena (data/tuning/arena.tres).

const GROUND_SHADER := """
shader_type spatial;
render_mode cull_back;
uniform vec4 color_a : source_color;
uniform vec4 color_b : source_color;
uniform vec4 grout : source_color;
uniform vec4 mark : source_color;
uniform float tile_size = 2.0;
uniform float radius = 18.0;
varying vec3 world_pos;
void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}
void fragment() {
	vec2 p = world_pos.xz / tile_size;
	vec2 cell = floor(p);
	vec2 f = fract(p);
	float checker = mod(cell.x + cell.y, 2.0);
	// per-tile brightness jitter
	float n = fract(sin(dot(cell, vec2(12.9898, 78.233))) * 43758.5453);
	vec3 c = mix(color_a.rgb, color_b.rgb, checker) * (0.92 + 0.16 * n);
	float edge = min(min(f.x, 1.0 - f.x), min(f.y, 1.0 - f.y));
	float g = 1.0 - smoothstep(0.015, 0.04, edge);
	c = mix(c, grout.rgb, g);
	float r = length(world_pos.xz);
	// concentric markings: center circle + inner boundary line
	float ring1 = 1.0 - smoothstep(0.05, 0.12, abs(r - 2.5));
	float ring2 = 1.0 - smoothstep(0.08, 0.16, abs(r - (radius - 1.0)));
	c = mix(c, mark.rgb, max(ring1, ring2) * 0.85);
	ALBEDO = c;
	ROUGHNESS = 0.85;
}
"""

const WALL_SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, blend_add, depth_draw_never, shadows_disabled;
uniform vec4 wall_color : source_color;
uniform float scroll = 0.6;
void fragment() {
	float v = UV.y; // 0 top .. 1 bottom on CylinderMesh
	float fade = pow(v, 2.2);
	float bands = 0.6 + 0.4 * sin((UV.y * 10.0 + TIME * scroll * 6.0) + sin(UV.x * 40.0) * 0.4);
	float bottom_glow = smoothstep(0.85, 1.0, v) * 1.5;
	ALBEDO = wall_color.rgb;
	ALPHA = clamp(wall_color.a * (fade * bands + bottom_glow), 0.0, 1.0);
}
"""

var radius: float = 0.0


func _init() -> void:
	name = "Arena"


func _ready() -> void:
	if radius <= 0.0:
		radius = Tuning.match_rules.arena_radius
	_build_environment()
	_build_ground()
	_build_ring()
	_build_scenery()


func _build_environment() -> void:
	var a := Tuning.arena
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = a.sky_top_color
	sky_mat.sky_horizon_color = a.sky_horizon_color
	sky_mat.ground_bottom_color = a.ground_bottom_color
	sky_mat.ground_horizon_color = a.ground_horizon_color
	sky_mat.sun_angle_max = 20.0
	var sky := Sky.new()
	sky.sky_material = sky_mat
	sky.radiance_size = Sky.RADIANCE_SIZE_64

	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = a.ambient_energy
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.glow_enabled = a.glow_enabled
	env.glow_intensity = 0.5
	env.glow_bloom = 0.05
	env.fog_enabled = true
	env.fog_light_color = a.sky_horizon_color
	env.fog_density = 0.002
	env.fog_sky_affect = 0.0

	var we := WorldEnvironment.new()
	we.name = "WorldEnvironment"
	we.environment = env
	add_child(we)

	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.rotation_degrees = Vector3(a.sun_pitch_deg, a.sun_yaw_deg, 0.0)
	sun.light_energy = a.sun_energy
	sun.light_color = Color(1.0, 0.97, 0.9)
	sun.shadow_enabled = true
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
	sun.directional_shadow_max_distance = a.shadow_max_distance
	sun.shadow_blur = 1.0
	add_child(sun)


func _build_ground() -> void:
	var a := Tuning.arena
	var mat := ShaderMaterial.new()
	var sh := Shader.new()
	sh.code = GROUND_SHADER
	mat.shader = sh
	mat.set_shader_parameter("color_a", a.tile_color_a)
	mat.set_shader_parameter("color_b", a.tile_color_b)
	mat.set_shader_parameter("grout", a.grout_color)
	mat.set_shader_parameter("mark", a.center_mark_color)
	mat.set_shader_parameter("tile_size", a.tile_size)
	mat.set_shader_parameter("radius", radius)

	var disc := CylinderMesh.new()
	disc.top_radius = radius
	disc.bottom_radius = radius + 0.4
	disc.height = 0.6
	disc.radial_segments = 96
	disc.rings = 1
	disc.material = mat
	var floor_mi := MeshInstance3D.new()
	floor_mi.name = "Floor"
	floor_mi.mesh = disc
	floor_mi.position.y = -0.3
	add_child(floor_mi)

	var outer := PlaneMesh.new()
	outer.size = Vector2.ONE * a.outer_ground_size
	outer.material = _flat_mat(a.outer_ground_color, 1.0)
	var outer_mi := MeshInstance3D.new()
	outer_mi.name = "OuterGround"
	outer_mi.mesh = outer
	outer_mi.position.y = -0.55
	outer_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(outer_mi)

	# Flat floor collider (top surface at y = 0).
	var body := StaticBody3D.new()
	body.name = "FloorBody"
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(a.outer_ground_size, 1.0, a.outer_ground_size)
	shape.shape = box
	shape.position.y = -0.5
	body.add_child(shape)
	add_child(body)


func _build_ring() -> void:
	var a := Tuning.arena
	var torus := TorusMesh.new()
	torus.inner_radius = radius
	torus.outer_radius = radius + a.edge_thickness * 2.0
	torus.rings = 96
	torus.ring_segments = 8
	torus.material = _flat_mat(a.edge_color, 0.95)
	var ring := MeshInstance3D.new()
	ring.name = "RingEdge"
	ring.mesh = torus
	ring.position.y = 0.0
	ring.scale = Vector3(1.0, 0.6, 1.0)
	add_child(ring)

	var wall_mat := ShaderMaterial.new()
	var sh := Shader.new()
	sh.code = WALL_SHADER
	wall_mat.shader = sh
	wall_mat.set_shader_parameter("wall_color", a.wall_color)
	wall_mat.set_shader_parameter("scroll", a.wall_scroll_speed)
	var cyl := CylinderMesh.new()
	cyl.top_radius = radius + 0.05
	cyl.bottom_radius = radius + 0.05
	cyl.height = a.wall_height
	cyl.cap_top = false
	cyl.cap_bottom = false
	cyl.radial_segments = 96
	cyl.rings = 1
	cyl.material = wall_mat
	var wall := MeshInstance3D.new()
	wall.name = "BoundaryWall"
	wall.mesh = cyl
	wall.position.y = a.wall_height * 0.5
	wall.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(wall)


func _build_scenery() -> void:
	var a := Tuning.arena
	var rng := RandomNumberGenerator.new()
	rng.seed = a.scenery_seed
	var scenery := Node3D.new()
	scenery.name = "Scenery"
	add_child(scenery)
	var rock_mat := _flat_mat(a.rock_color, 1.0)

	for i in a.boulder_count:
		var ang := TAU * (i + rng.randf_range(-0.3, 0.3)) / maxf(a.boulder_count, 1)
		var dist := radius + rng.randf_range(a.scenery_min_gap, a.scenery_max_gap)
		var s := rng.randf_range(0.8, 2.6)
		var m := SphereMesh.new()
		m.radius = 1.0
		m.height = 2.0
		m.radial_segments = 10
		m.rings = 6
		m.material = rock_mat
		var mi := MeshInstance3D.new()
		mi.mesh = m
		mi.position = Vector3(cos(ang) * dist, s * 0.25, sin(ang) * dist)
		mi.scale = Vector3(s * rng.randf_range(0.9, 1.5), s * rng.randf_range(0.5, 0.8), s)
		mi.rotation.y = rng.randf() * TAU
		scenery.add_child(mi)

	for i in a.pillar_count:
		var ang := TAU * (i + 0.5 + rng.randf_range(-0.2, 0.2)) / maxf(a.pillar_count, 1)
		var dist := radius + rng.randf_range(a.scenery_min_gap + 2.0, a.scenery_max_gap)
		var h := rng.randf_range(4.0, 12.0)
		var m := CylinderMesh.new()
		m.top_radius = rng.randf_range(0.6, 1.4)
		m.bottom_radius = m.top_radius * rng.randf_range(1.2, 1.8)
		m.height = h
		m.radial_segments = 7
		m.material = rock_mat
		var mi := MeshInstance3D.new()
		mi.mesh = m
		mi.position = Vector3(cos(ang) * dist, h * 0.5 - 0.5, sin(ang) * dist)
		mi.rotation = Vector3(rng.randf_range(-0.12, 0.12), rng.randf() * TAU, rng.randf_range(-0.12, 0.12))
		scenery.add_child(mi)

	var mount_mat := _flat_mat(a.mountain_color, 1.0)
	for i in a.mountain_count:
		var ang := TAU * (i + rng.randf_range(-0.35, 0.35)) / maxf(a.mountain_count, 1)
		var dist := a.mountain_distance * rng.randf_range(0.8, 1.2)
		var h := rng.randf_range(25.0, 60.0)
		var m := CylinderMesh.new()
		m.top_radius = rng.randf_range(0.0, 4.0)
		m.bottom_radius = h * rng.randf_range(0.7, 1.1)
		m.height = h
		m.radial_segments = 8
		m.rings = 1
		m.material = mount_mat
		var mi := MeshInstance3D.new()
		mi.mesh = m
		mi.position = Vector3(cos(ang) * dist, h * 0.5 - 1.0, sin(ang) * dist)
		mi.rotation.y = rng.randf() * TAU
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		scenery.add_child(mi)


static func _flat_mat(color: Color, roughness: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = roughness
	return m
