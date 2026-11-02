class_name BeachArena
extends Arena
## The sand behind a beach bar on the orla of João Pessoa, in the days tables
## were allowed on the sand. Visual only, like every Arena: the play area is
## the rope circle of `radius`, and everything else stands outside it, so the
## fighters never meet a prop. Looking at -Z: plastic tables and chairs, the
## back of the bar, palms, the city. Looking at +Z: umbrellas, then the sea.
## Reads Tuning.arena_beach (data/tuning/arena_beach.tres). Repeated props are
## MultiMeshes of one PropMesh each; the only per-prop nodes are the wordmarks.

const NOISE_GLSL := """
float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}
float noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), f.x),
			mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), f.x), f.y);
}
float fbm(vec2 p) {
	return noise(p) * 0.55 + noise(p * 2.1 + 3.7) * 0.3 + noise(p * 4.3 + 9.1) * 0.15;
}
"""

const BEACH_SHADER := """
shader_type spatial;
render_mode cull_back;
uniform vec4 sand_light : source_color;
uniform vec4 sand_dark : source_color;
uniform vec4 sand_wet : source_color;
uniform vec4 grass : source_color;
uniform vec4 promenade : source_color;
uniform vec4 water_shallow : source_color;
uniform vec4 water_deep : source_color;
uniform vec4 water_glint : source_color;
uniform vec4 foam : source_color;
uniform float radius = 18.0;
uniform float shore_z = 35.0;
uniform float shore_bend = 0.001;
uniform float grass_z = -44.0;
uniform float grass_depth = 12.0;
uniform float promenade_width = 9.0;
uniform float swash_reach = 2.5;
uniform float swash_speed = 0.5;
uniform float wet_width = 3.5;
uniform float breaker_spacing = 17.0;
uniform float breaker_speed = 0.05;
varying vec3 world_pos;

//NOISE
void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}
void fragment() {
	vec2 p = world_pos.xz;
	float view_dist = length(world_pos - CAMERA_POSITION_WORLD);
	float near_detail = 1.0 - smoothstep(25.0, 70.0, view_dist);
	float d = p.y - (shore_z - shore_bend * p.x * abs(p.x));
	float wobble = noise(vec2(p.x * 0.07, TIME * 0.05)) * 3.0;
	float swash = (sin(TIME * swash_speed + p.x * 0.035 + wobble) * 0.5 + 0.5) * swash_reach;

	// Dry sand: broad tone, wind ripples, grain, scuffed inside the rope.
	float tone = fbm(p * 0.13);
	float ripples = sin((p.y + fbm(p * 0.09) * 14.0) * 4.5) * 0.5 + 0.5;
	float grain = hash(floor(p * 38.0));
	vec3 sand = mix(sand_light.rgb, sand_dark.rgb, clamp(tone * 1.3 - 0.2, 0.0, 1.0));
	float scuff = (1.0 - smoothstep(radius - 1.5, radius + 0.5, length(p))) * smoothstep(0.35, 0.65, fbm(p * 0.5));
	sand = mix(sand, sand_dark.rgb, scuff * 0.45);
	sand *= 1.0 + (ripples - 0.5) * 0.09 * near_detail + (grain - 0.5) * 0.09 * near_detail;
	float wet = smoothstep(-wet_width - swash_reach, -swash_reach * 0.25, d);
	sand = mix(sand, sand_wet.rgb, wet * 0.85);
	float rough = mix(0.95, 0.3, wet);

	// Past the sand: grass, then the promenade, following the bay.
	float land = p.y + shore_bend * p.x * abs(p.x) - grass_z;
	float edge = (fbm(vec2(p.x * 0.04, 1.3)) - 0.5) * 7.0;
	float on_grass = 1.0 - smoothstep(-0.5, 0.5, land - edge);
	vec3 c = mix(sand, grass.rgb * (0.75 + tone * 0.55), on_grass);
	float on_walk = 1.0 - smoothstep(-0.2, 0.2, land + grass_depth);
	c = mix(c, promenade.rgb, on_walk);
	c = mix(c, promenade.rgb * 0.45, 1.0 - smoothstep(-0.2, 0.2, land + grass_depth + promenade_width));

	// The sea, skipped on dry land.
	float water = smoothstep(-0.25, 0.25, d + swash);
	if (d + swash > -1.0) {
	float depth = smoothstep(0.0, 130.0, d);
	vec3 sea = mix(water_shallow.rgb, water_deep.rgb, sqrt(depth));
	sea = mix(sea, water_glint.rgb, smoothstep(40.0, 260.0, d) * 0.42);
	float chop = noise(vec2(p.x * 0.22 + TIME * 0.2, p.y * 0.5 - TIME * 0.35));
	sea *= 0.9 + chop * 0.2;
	float wave_d = d + (noise(vec2(p.x * 0.03, 7.0)) - 0.5) * 9.0;
	float phase = fract(wave_d / breaker_spacing + TIME * breaker_speed);
	float band = smoothstep(0.0, 0.03, phase) * (1.0 - smoothstep(0.03, 0.16, phase));
	float lacy = smoothstep(0.3, 0.6, fbm(vec2(p.x * 0.3, p.y * 0.9 + TIME * 0.2)));
	float breakers = band * lacy * (1.0 - smoothstep(35.0, 75.0, d));
	float lip = smoothstep(-0.5, 0.0, d + swash) * (1.0 - smoothstep(0.0, 1.6, d + swash));
	lip *= 0.55 + 0.45 * lacy;
	float foamy = clamp(max(breakers, lip), 0.0, 1.0);
	c = mix(c, sea, water);
	c = mix(c, foam.rgb, foamy * water);
	rough = mix(rough, mix(0.16, 0.8, foamy), water);
	}

	// Ripple normals on the water and on the shine of wet sand.
	if (water + wet > 0.0) {
		float e = 0.35;
		float h0 = noise(p * 0.8 + TIME * 0.5);
		vec2 slope = vec2(noise(p * 0.8 + vec2(e, 0.0) + TIME * 0.5) - h0, noise(p * 0.8 + vec2(0.0, e) + TIME * 0.5) - h0);
		float bump = (water * 0.7 + wet * 0.08) * mix(0.15, 1.0, near_detail);
		vec3 wn = normalize(vec3(-slope.x * bump, 1.0, -slope.y * bump));
		NORMAL = normalize((VIEW_MATRIX * vec4(wn, 0.0)).xyz);
	}
	ALBEDO = c;
	ROUGHNESS = rough;
	SPECULAR = 0.35;
}
"""

const SKY_SHADER := """
shader_type sky;
uniform vec3 top : source_color;
uniform vec3 horizon : source_color;
uniform vec3 cloud_lit : source_color;
uniform vec3 cloud_shade : source_color;
uniform vec3 sun_glow : source_color;
uniform float cover = 0.56;
uniform float cloud_scale = 1.9;

//NOISE
void sky() {
	vec3 d = EYEDIR;
	float h = max(d.y, 0.0);
	vec3 c = mix(horizon, top, 1.0 - exp(-h * 9.0));
	float toward_sun = max(dot(d, LIGHT0_DIRECTION), 0.0);
	c = mix(c, sun_glow, pow(toward_sun, 14.0) * 0.5);
	if (d.y > 0.005) {
		// Static on purpose: TIME here would redraw the radiance every frame.
		vec2 uv = d.xz / (d.y + 0.16) * cloud_scale;
		float n = fbm(uv);
		float mask = smoothstep(cover, cover + 0.14, n) * smoothstep(0.01, 0.09, d.y);
		float thick = smoothstep(cover + 0.03, cover + 0.3, fbm(uv - normalize(LIGHT0_DIRECTION.xz) * 0.12));
		vec3 cloud = mix(cloud_lit, cloud_shade, thick);
		c = mix(c, cloud, mask * 0.95);
	}
	c += sun_glow * pow(toward_sun, 900.0) * 3.0;
	COLOR = c;
}
"""

const TOWER_SHADER := """
shader_type spatial;
render_mode cull_back;
varying vec3 world_pos;
varying vec3 world_n;
void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_n = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}
void fragment() {
	float across = abs(world_n.x) > 0.5 ? world_pos.z : world_pos.x;
	float side = 1.0 - abs(world_n.y);
	float floors = smoothstep(0.35, 0.5, abs(fract(world_pos.y / 3.0) - 0.5));
	float bays = smoothstep(0.3, 0.42, abs(fract(across / 3.5) - 0.5));
	vec3 paint = pow(COLOR.rgb, vec3(2.2));  // instance colours are sRGB, as on PropMesh.material()
	ALBEDO = paint * (1.0 - side * 0.32 * floors * (0.4 + 0.6 * bays));
	ROUGHNESS = 0.75;
}
"""

const CHAIR_SEAT_HEIGHT := 0.44
const TABLE_HEIGHT := 0.74
const TABLE_SIZE := 0.82
## Distance from a table's centre to its chairs' seats.
const CHAIR_RING := 0.72
const CRATE_SIZE := Vector3(0.48, 0.3, 0.34)
const BAR_WALL_HEIGHT := 3.1
const BAR_ROOF_HEIGHT := 2.4
const BAR_EAVE := 1.5
const AWNING_DEPTH := 3.4
const UMBRELLA_RADIUS := 1.7
const UMBRELLA_HEIGHT := 2.35
## The hill closing the bay.
const HEADLAND_SIZE := Vector3(150.0, 30.0, 95.0)
const ROPE_POINTS_PER_STAKE := 5
const ROPE_SAG := 0.09
const ROPE_RADIUS := 0.026
## How far inside the camera's far plane the last tower stands.
const FAR_MARGIN := 40.0

var _props: Node3D
var _prop_mat: StandardMaterial3D
var _rng := RandomNumberGenerator.new()


func look() -> ArenaTuning:
	return Tuning.arena_beach


func _make_sky_material() -> Material:
	var b := Tuning.arena_beach
	var mat := ShaderMaterial.new()
	var sh := Shader.new()
	sh.code = SKY_SHADER.replace("//NOISE", NOISE_GLSL)
	mat.shader = sh
	mat.set_shader_parameter("top", b.sky_top_color)
	mat.set_shader_parameter("horizon", b.sky_horizon_color)
	mat.set_shader_parameter("cloud_lit", b.cloud_lit)
	mat.set_shader_parameter("cloud_shade", b.cloud_shade)
	mat.set_shader_parameter("sun_glow", b.sun_glow)
	mat.set_shader_parameter("cover", b.cloud_cover)
	mat.set_shader_parameter("cloud_scale", b.cloud_scale)
	return mat


func _build_environment() -> void:
	super()
	if RenderingServer.get_current_rendering_method() != "gl_compatibility":
		return
	var scale := Tuning.arena_beach.compatibility_light_scale
	_sun.light_energy *= scale
	var env: Environment = (get_node("WorldEnvironment") as WorldEnvironment).environment
	env.ambient_light_energy *= scale


# --- layout (no nodes, so tests can check it against the play circle) ---------

## Waterline's z at x.
static func shore_z(x: float, play_radius: float) -> float:
	var b := Tuning.arena_beach
	return play_radius + b.shore_gap - b.shore_bend * x * absf(x)


## A z measured on land at x = 0, carried along the bay to x.
static func land_z(x: float, z: float) -> float:
	return z - Tuning.arena_beach.shore_bend * x * absf(x)


## Rear wall of the bar (its face toward the sand).
static func bar_z(play_radius: float) -> float:
	return -(play_radius + Tuning.arena_beach.bar_gap)


## Table positions (x, z): arcs facing the bar.
static func table_spots(play_radius: float) -> PackedVector2Array:
	var b := Tuning.arena_beach
	return _arc_spots(play_radius, b.table_row_gaps, b.table_spacing, b.table_arc_deg, -1.0)


## Umbrella positions (x, z): arcs facing the sea.
static func umbrella_spots(play_radius: float) -> PackedVector2Array:
	var b := Tuning.arena_beach
	return _arc_spots(play_radius, b.umbrella_row_gaps, b.umbrella_spacing, b.umbrella_arc_deg, 1.0)


## One arc per gap around the z axis (side = -1: -Z), spots `spacing` apart,
## every other row shifted half a step so rows don't line up.
static func _arc_spots(play_radius: float, gaps: PackedFloat32Array, spacing: float, arc_deg: float,
		side: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	var half := deg_to_rad(arc_deg) * 0.5
	for row in gaps.size():
		var r := play_radius + gaps[row]
		var step := spacing / r
		var count := int(half * 2.0 / step)
		var start := -step * (count - 1) * 0.5 + (step * 0.5 if row % 2 == 1 else 0.0)
		for i in count:
			var a := start + step * i
			if absf(a) <= half:
				out.append(Vector2(sin(a), cos(a) * side) * r)
	return out


# --- stage ----------------------------------------------------------------------

func _build_ground() -> void:
	var b := Tuning.arena_beach
	var mat := ShaderMaterial.new()
	var sh := Shader.new()
	sh.code = BEACH_SHADER.replace("//NOISE", NOISE_GLSL)
	mat.shader = sh
	for key: String in ["sand_light", "sand_dark", "sand_wet", "water_shallow", "water_deep", "water_glint",
			"swash_reach", "swash_speed", "wet_width", "breaker_spacing", "breaker_speed", "shore_bend",
			"grass_depth", "promenade_width"]:
		mat.set_shader_parameter(key, b.get(key))
	mat.set_shader_parameter("grass", b.grass_color)
	mat.set_shader_parameter("promenade", b.promenade_color)
	mat.set_shader_parameter("foam", b.foam_color)
	mat.set_shader_parameter("radius", radius)
	mat.set_shader_parameter("shore_z", shore_z(0.0, radius))
	mat.set_shader_parameter("grass_z", -(radius + b.grass_gap))

	var plane := PlaneMesh.new()
	plane.size = Vector2.ONE * b.outer_ground_size
	plane.material = mat
	var ground := MeshInstance3D.new()
	ground.name = "Beach"
	ground.mesh = plane
	ground.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(ground)
	_build_floor_body()


## The play boundary: a rope on wooden stakes, in place of the energy wall.
func _build_ring() -> void:
	var b := Tuning.arena_beach
	_prop_mat = PropMesh.material()
	_props = Node3D.new()
	_props.name = "Props"
	add_child(_props)

	var stake := PropMesh.new()
	stake.rod(Vector3.ZERO, Vector3.UP * (b.rope_height + 0.12), 0.05, 0.04, 6, b.wood_color)
	var stakes: Array = []
	var ring_at := radius + 0.1
	var count := maxi(int(TAU * ring_at / b.rope_stake_spacing), 3)
	for i in count:
		var a := TAU * i / count
		stakes.append([Transform3D(Basis.IDENTITY, Vector3(cos(a), 0.0, sin(a)) * ring_at), Color.WHITE])
	_batch("Stakes", stake.commit(), stakes)

	# Sagging between stakes, in one tube.
	var rope := PropMesh.new()
	var points := PackedVector3Array()
	var radii := PackedFloat32Array()
	for i in count * ROPE_POINTS_PER_STAKE + 1:
		var t := float(i) / ROPE_POINTS_PER_STAKE
		var a := TAU * t / count
		var sag := ROPE_SAG * (1.0 - pow(2.0 * fmod(t, 1.0) - 1.0, 2.0))
		points.append(Vector3(cos(a) * ring_at, b.rope_height - sag, sin(a) * ring_at))
		radii.append(ROPE_RADIUS)
	rope.tube(points, radii, 5, b.rope_color)
	_add_static("Rope", rope.commit())


func _build_scenery() -> void:
	_rng.seed = look().scenery_seed
	_build_tables()
	_build_bar()
	_build_umbrellas()
	_build_palms()
	_build_city()


func _build_tables() -> void:
	var b := Tuning.arena_beach
	var chair_mesh := _chair_mesh()
	var table_mesh := _table_mesh()
	var bottle_mesh := _bottle_mesh()
	var tables: Array = []
	var chairs: Array = []
	var bottles: Array = []
	var spots := table_spots(radius)
	for i in spots.size():
		var brand_a := i % 2 == 0
		var pos := Vector3(spots[i].x, 0.0, spots[i].y)
		var yaw := _rng.randf_range(-0.2, 0.2)
		var turn := Basis(Vector3.UP, yaw)
		var color := b.brand_a_color if brand_a else b.brand_b_color
		tables.append([Transform3D(turn, pos), color])
		_add_table_mark(pos, yaw, brand_a)
		for seat in 4:
			if _rng.randf() < b.chair_missing_chance:
				continue
			var a := yaw + TAU * seat / 4.0
			var seat_pos := pos + Vector3(sin(a), 0.0, cos(a)) * (CHAIR_RING + _rng.randf_range(0.0, 0.3))
			var facing := a + PI + _rng.randf_range(-0.35, 0.35)
			var basis := Basis(Vector3.UP, facing)
			if _rng.randf() < b.chair_toppled_chance:
				# On its back, a little further out.
				basis = basis * Basis(Vector3.RIGHT, -PI * 0.5)
				seat_pos += Vector3(sin(a), 0.0, cos(a)) * 0.6 + Vector3.UP * 0.22
			chairs.append([Transform3D(basis, seat_pos), color])
		for n in _rng.randi_range(1, 3):
			var off := Vector3(_rng.randf_range(-0.28, 0.28), TABLE_HEIGHT + 0.02, _rng.randf_range(-0.28, 0.28))
			bottles.append([Transform3D(Basis.IDENTITY, pos + off), Color.WHITE])
	# Spare chairs stacked by the bar, the way they are at closing time.
	var z := bar_z(radius) + 1.3
	for s: int in 2:
		var x := -b.bar_width * 0.5 + 1.2 + s * 1.0
		for n in 6 + s * 3:
			chairs.append([Transform3D(Basis.IDENTITY, Vector3(x, n * 0.075, z)), b.chair_white])
	_batch("Tables", table_mesh, tables)
	_batch("Chairs", chair_mesh, chairs)
	_batch("Bottles", bottle_mesh, bottles)


func _build_umbrellas() -> void:
	var b := Tuning.arena_beach
	var chair_mesh := _chair_mesh()
	var by_color: Dictionary = {}
	var chairs: Array = []
	var spots := umbrella_spots(radius)
	for i in spots.size():
		var pos := Vector3(spots[i].x + _rng.randf_range(-0.5, 0.5), 0.0, spots[i].y + _rng.randf_range(-0.5, 0.5))
		var color: Color = b.umbrella_colors[_rng.randi() % b.umbrella_colors.size()]
		var tilt := Basis(Vector3.UP, _rng.randf() * TAU) * Basis(Vector3.RIGHT, _rng.randf_range(-0.07, 0.07))
		if not by_color.has(color):
			by_color[color] = []
		by_color[color].append([Transform3D(tilt, pos), Color.WHITE])
		for seat in 2:
			var side := -1.0 if seat == 0 else 1.0
			var at := pos + Vector3(side * 0.7, 0.0, _rng.randf_range(-0.2, 0.2))
			# Facing the sea.
			chairs.append([Transform3D(Basis(Vector3.UP, side * 0.25), at), b.chair_white])
	for color: Color in by_color:
		_batch("Umbrellas", _umbrella_mesh(color), by_color[color])
	_batch("BeachChairs", chair_mesh, chairs)


func _build_palms() -> void:
	var b := Tuning.arena_beach
	var variants: Array[ArrayMesh] = [_palm_mesh(0.9, 8.5), _palm_mesh(-0.8, 10.5), _palm_mesh(1.4, 7.0)]
	var items: Array = [[], [], []]
	var back := -radius - b.grass_gap
	for i in b.palm_count:
		var x := _rng.randf_range(-1.0, 1.0)
		var pos := Vector3(x * b.palm_span, 0.0, 0.0)
		if absf(pos.x) < b.bar_width * 0.5 + 3.0:
			pos.x = signf(x) * (b.bar_width * 0.5 + 3.0 + absf(x) * 8.0)
		pos.z = land_z(pos.x, back + _rng.randf_range(-b.grass_depth, 2.0))
		var s := _rng.randf_range(0.85, 1.25)
		items[i % variants.size()].append([
			Transform3D(Basis(Vector3.UP, _rng.randf() * TAU).scaled(Vector3.ONE * s), pos), Color.WHITE])
	for i in variants.size():
		_batch("Palms", variants[i], items[i])


func _build_city() -> void:
	var b := Tuning.arena_beach
	var box := BoxMesh.new()
	var mat := ShaderMaterial.new()
	var sh := Shader.new()
	sh.code = TOWER_SHADER
	mat.shader = sh
	box.material = mat
	var towers: Array = []
	for i in b.tower_count:
		var x := _rng.randf_range(-b.tower_span * 0.45, b.tower_span)
		var inland := _rng.randf_range(0.0, 1.0)
		inland *= inland
		var road := -radius - b.grass_gap - b.grass_depth - b.promenade_width
		var z := land_z(x, road - lerpf(b.tower_min_inland, b.tower_max_inland, inland))
		# The bay's curve must not carry it past the far plane or off the ground.
		var at := Vector2(x, z).limit_length(minf(Tuning.camera.far, b.outer_ground_size * 0.5) - FAR_MARGIN)
		var h := lerpf(b.tower_height_front, b.tower_height_back, sqrt(inland)) * _rng.randf_range(0.55, 1.15)
		var size := Vector3(_rng.randf_range(11.0, 22.0), h, _rng.randf_range(11.0, 22.0))
		var basis := Basis(Vector3.UP, _rng.randf_range(-0.12, 0.12)) * Basis.from_scale(size)
		var color: Color = b.tower_colors[_rng.randi() % b.tower_colors.size()]
		towers.append([Transform3D(basis, Vector3(at.x, h * 0.5, at.y)), color])
	_batch("Towers", box, towers, false)

	# Ponta do Cabo Branco closing the bay on the far side.
	var hill := SphereMesh.new()
	hill.radius = 1.0
	hill.height = 2.0
	hill.radial_segments = 16
	hill.rings = 8
	hill.material = Arena._flat_mat(b.headland_color, 1.0)
	var hm := MeshInstance3D.new()
	hm.name = "Headland"
	hm.mesh = hill
	hm.position = Vector3(b.headland_x, 0.0, shore_z(b.headland_x, radius) - HEADLAND_SIZE.z * 0.6)
	hm.scale = HEADLAND_SIZE
	hm.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(hm)


func _build_bar() -> void:
	var b := Tuning.arena_beach
	var m := PropMesh.new()
	var w := b.bar_width
	var d := b.bar_depth
	var z0 := bar_z(radius)  # the rear wall, facing the sand
	var zc := z0 - d * 0.5
	var y1 := BAR_WALL_HEIGHT
	var ytop := y1 + BAR_ROOF_HEIGHT
	var trim := b.wall_trim
	m.block(Vector3(0.0, y1 * 0.5, zc), Vector3(w, y1, d), b.wall_paint)
	# White plinth and corner trim, weathered planks.
	m.block(Vector3(0.0, 0.3, z0 + 0.02), Vector3(w + 0.1, 0.6, 0.06), trim)
	for sx: float in [-1.0, 1.0]:
		m.block(Vector3(sx * (w * 0.5 - 0.08), y1 * 0.5, z0 + 0.03), Vector3(0.2, y1, 0.08), trim)
	for i in 34:
		var x := -w * 0.5 + w * (i + 0.5) / 34.0
		var shade := Color(0.0, 0.0, 0.0).lerp(b.wall_paint, 0.72 + 0.1 * (i % 3))
		m.block(Vector3(x, y1 * 0.55, z0 + 0.012), Vector3(0.025, y1 * 0.84, 0.02), shade)

	# Thatch roof: hips of palm straw, sticking out over the sand.
	var e := BAR_EAVE
	var thatch := b.thatch_color
	var hl := w * 0.5 + e
	var ridge := w * 0.3
	var back := z0 - d - e
	var front := z0 + e
	var mid := (front + back) * 0.5
	var fl := Vector3(-hl, y1 - 0.15, front)
	var fr := Vector3(hl, y1 - 0.15, front)
	var bl := Vector3(-hl, y1 - 0.15, back)
	var br := Vector3(hl, y1 - 0.15, back)
	var rl := Vector3(-ridge, ytop, mid)
	var rr := Vector3(ridge, ytop, mid)
	m.quad(fl, fr, rr, rl, thatch)
	m.quad(fr, br, rr, rr, thatch.darkened(0.1))
	m.quad(br, bl, rl, rr, thatch.darkened(0.2))
	m.quad(bl, fl, rl, rl, thatch.darkened(0.1))
	m.quad(fl, bl, br, fr, b.wood_color)  # underside
	m.block(Vector3(0.0, ytop + 0.04, mid), Vector3(ridge * 2.0 + 0.4, 0.16, 0.3), thatch.darkened(0.3))
	for i in 12:  # uneven straw fringe
		var x := -hl + hl * 2.0 * (i + 0.5) / 12.0
		var drop := 0.28 + 0.14 * (i % 3)
		m.block(Vector3(x, y1 - 0.15 - drop * 0.3, front - 0.05), Vector3(hl * 2.0 / 12.0 + 0.02, drop, 0.12), thatch.darkened(0.08 * (i % 2)))

	# Service hatch with a counter and stools; steel door to the store room.
	var hatch_x := w * 0.14
	var hatch_w := 5.2
	m.block(Vector3(hatch_x, 1.8, z0 + 0.02), Vector3(hatch_w, 1.15, 0.05), Color(0.07, 0.06, 0.06))
	m.block(Vector3(hatch_x, 1.13, z0 + 0.22), Vector3(hatch_w + 0.3, 0.09, 0.5), b.wood_color)
	m.block(Vector3(hatch_x, 2.42, z0 + 0.1), Vector3(hatch_w + 0.3, 0.1, 0.2), trim)
	for i in 5:
		var x := hatch_x - hatch_w * 0.4 + hatch_w * 0.2 * i
		m.rod(Vector3(x, 0.0, z0 + 0.62), Vector3(x, 0.68, z0 + 0.62), 0.03, 0.03, 6, Color(0.6, 0.6, 0.6))
		m.rod(Vector3(x, 0.68, z0 + 0.62), Vector3(x, 0.74, z0 + 0.62), 0.17, 0.17, 10, Color(0.7, 0.12, 0.1))
	for i in 7:  # bottles on the shelf behind the hatch
		var x := hatch_x - hatch_w * 0.4 + hatch_w * 0.8 * i / 6.0
		m.rod(Vector3(x, 1.2, z0 + 0.3), Vector3(x, 1.46, z0 + 0.3), 0.04, 0.02, 6, Color(0.3, 0.16, 0.05))
	var door_x := -w * 0.14
	m.block(Vector3(door_x, 1.05, z0 + 0.03), Vector3(1.1, 2.1, 0.06), Color(0.55, 0.57, 0.58))
	m.block(Vector3(door_x + 0.4, 1.0, z0 + 0.08), Vector3(0.06, 0.2, 0.06), Color(0.2, 0.2, 0.2))
	# Chest freezer by the wall.
	var fx := w * 0.5 - 2.2
	m.block(Vector3(fx, 0.45, z0 + 0.5), Vector3(1.5, 0.9, 0.75), Color(0.92, 0.92, 0.92))
	m.block(Vector3(fx, 0.5, z0 + 0.89), Vector3(1.4, 0.34, 0.01), b.brand_a_color)
	m.block(Vector3(fx, 0.93, z0 + 0.5), Vector3(1.52, 0.06, 0.77), Color(0.75, 0.75, 0.75))
	# Trash drum.
	m.rod(Vector3(-w * 0.5 - 0.9, 0.0, z0 + 0.8), Vector3(-w * 0.5 - 0.9, 0.9, z0 + 0.8), 0.3, 0.3, 12, Color(0.2, 0.32, 0.5))
	# Wooden posts holding the awning.
	var awn_front := z0 + AWNING_DEPTH
	var awn_w := w * 0.62
	var awn_low := 2.25
	for i in 4:
		var x := -awn_w * 0.5 + awn_w * i / 3.0
		m.rod(Vector3(x, 0.0, awn_front), Vector3(x, awn_low, awn_front), 0.07, 0.06, 7, b.wood_color)
	_add_static("Bar", m.commit())

	# Striped tarp, two-sided.
	var tarp := PropMesh.new()
	var stripes := 12
	for i in stripes:
		var x0 := -awn_w * 0.5 + awn_w * i / stripes
		var x1 := -awn_w * 0.5 + awn_w * (i + 1) / stripes
		var c := b.brand_a_color if i % 2 == 0 else b.brand_a_text_color
		var hi := Vector3(0.0, 2.95, z0 + 0.02)
		var lo := Vector3(0.0, awn_low + 0.05, awn_front + 0.2)
		tarp.two_sided_quad(Vector3(x0, lo.y, lo.z), Vector3(x1, lo.y, lo.z), Vector3(x1, hi.y, hi.z), Vector3(x0, hi.y, hi.z), c)
	_add_static("Awning", tarp.commit())

	# Crates by the door: yellow and blue, bottle caps showing.
	var crate := _crate_mesh()
	var crates: Array = []
	var cx := door_x - 2.4
	for col in 3:
		for row in 4 - col:
			var c := b.brand_a_color if (col + row) % 2 == 0 else b.brand_b_color
			var at := Vector3(cx + col * 0.52 + _rng.randf_range(-0.02, 0.02), CRATE_SIZE.y * (row + 0.5), z0 + 0.55)
			crates.append([Transform3D(Basis(Vector3.UP, _rng.randf_range(-0.05, 0.05)), at), c])
	_batch("Crates", crate, crates)

	# Signs.
	var top_y := ytop + 0.55
	var board := PropMesh.new()
	var sign_z := mid + 0.25
	board.block(Vector3(0.0, top_y, sign_z), Vector3(7.6, 1.15, 0.1), b.wall_trim)
	for sx: float in [-1.0, 1.0]:
		board.block(Vector3(sx * 3.0, ytop - 0.6, sign_z - 0.08), Vector3(0.12, 1.8, 0.08), b.wood_color)
	_add_static("SignBoard", board.commit())
	_add_text(b.bar_sign, Transform3D(Basis.IDENTITY, Vector3(0.0, top_y, sign_z + 0.07)),
			b.wall_paint.darkened(0.35), 0.0135, 96)
	_add_banner(Vector3(-w * 0.405, 1.85, z0), b.brand_a_name, b.brand_a_color, b.brand_a_text_color)
	_add_banner(Vector3(w * 0.37, 1.95, z0), b.brand_b_name, b.brand_b_color, b.brand_b_text_color)
	_add_text(b.brand_a_name, Transform3D(Basis.IDENTITY, Vector3(fx, 0.5, z0 + 0.91)), b.brand_a_text_color, 0.007, 64)


## A cloth banner on the wall.
func _add_banner(at: Vector3, text: String, color: Color, text_color: Color) -> void:
	var cloth := PropMesh.new()
	var size := Vector3(3.6, 1.15, 0.03)
	cloth.block(at + Vector3(0.0, 0.0, 0.08), size, color)
	_add_static("Banner", cloth.commit())
	var pixel := 0.012 if text.length() < 6 else 0.0056
	_add_text(text, Transform3D(Basis.IDENTITY, at + Vector3(0.0, 0.0, 0.11)), text_color, pixel, 96)


func _add_table_mark(pos: Vector3, yaw: float, brand_a: bool) -> void:
	var b := Tuning.arena_beach
	var text := b.brand_a_name if brand_a else b.brand_b_name
	var color := b.brand_a_text_color if brand_a else b.brand_b_text_color
	var pixel := 0.0042 if text.length() < 6 else 0.0024
	var flat := Basis(Vector3.UP, yaw) * Basis(Vector3.RIGHT, -PI * 0.5)
	_add_text(text, Transform3D(flat, pos + Vector3.UP * (TABLE_HEIGHT + 0.022)), color, pixel, 64)


func _add_text(text: String, xf: Transform3D, color: Color, pixel: float, size: int) -> void:
	var l := Label3D.new()
	l.text = text
	l.transform = xf
	l.pixel_size = pixel
	l.font_size = size
	l.outline_size = 0
	l.modulate = color
	l.shaded = true
	l.double_sided = false
	l.no_depth_test = false
	l.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_props.add_child(l)


func _add_static(node_name: String, mesh: ArrayMesh) -> void:
	var mi := MeshInstance3D.new()
	mi.name = node_name
	mi.mesh = mesh
	mi.material_override = _prop_mat
	_props.add_child(mi)


## items: [Transform3D, Color] pairs. `use_prop_material` = false keeps the
## mesh's own one.
func _batch(node_name: String, mesh: Mesh, items: Array, use_prop_material := true) -> void:
	if items.is_empty():
		return
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = mesh
	mm.instance_count = items.size()
	for i in items.size():
		mm.set_instance_transform(i, items[i][0])
		mm.set_instance_color(i, items[i][1])
	var mi := MultiMeshInstance3D.new()
	mi.name = node_name
	mi.multimesh = mm
	if use_prop_material:
		mi.material_override = _prop_mat
	_props.add_child(mi)


# --- prop meshes (local origin on the ground) --------------------------------

## A monobloc chair facing +z, tinted by the instance colour.
static func _chair_mesh() -> ArrayMesh:
	var m := PropMesh.new()
	var c := Color.WHITE
	var y := CHAIR_SEAT_HEIGHT
	m.block(Vector3(0.0, y, 0.0), Vector3(0.46, 0.04, 0.44), c)
	# Flared legs.
	for sx: float in [-1.0, 1.0]:
		for sz: float in [-1.0, 1.0]:
			m.rod(Vector3(sx * 0.2, y, sz * 0.19), Vector3(sx * 0.27, 0.0, sz * 0.26), 0.04, 0.028, 6, c)
	# Reclined slatted back, joined by a top rail.
	var back := Basis(Vector3.RIGHT, -0.22)
	var pivot := Vector3(0.0, y, -0.21)
	for i in 5:
		var x := -0.18 + 0.09 * i
		m.box(Transform3D(back, pivot + back * Vector3(x, 0.2, 0.0)), Vector3(0.055, 0.4, 0.025), c)
	m.box(Transform3D(back, pivot + back * Vector3(0.0, 0.42, 0.0)), Vector3(0.46, 0.085, 0.035), c)
	m.box(Transform3D(back, pivot + back * Vector3(0.0, 0.06, 0.0)), Vector3(0.46, 0.05, 0.03), c)
	# Armrests.
	for sx: float in [-1.0, 1.0]:
		m.block(Vector3(sx * 0.245, y + 0.2, -0.02), Vector3(0.05, 0.025, 0.4), c)
		m.rod(Vector3(sx * 0.235, y, 0.15), Vector3(sx * 0.245, y + 0.2, 0.15), 0.018, 0.018, 5, c)
	return m.commit()


## Square plastic bar table, tinted by the instance colour.
static func _table_mesh() -> ArrayMesh:
	var m := PropMesh.new()
	var c := Color.WHITE
	var t := TABLE_SIZE
	var y := TABLE_HEIGHT
	m.block(Vector3(0.0, y, 0.0), Vector3(t, 0.035, t), c)
	var under := Color(0.82, 0.82, 0.82)
	for s: float in [-1.0, 1.0]:
		m.block(Vector3(0.0, y - 0.05, s * (t * 0.5 - 0.02)), Vector3(t, 0.07, 0.025), under)
		m.block(Vector3(s * (t * 0.5 - 0.02), y - 0.05, 0.0), Vector3(0.025, 0.07, t), under)
		for z: float in [-1.0, 1.0]:
			m.rod(Vector3(s * (t * 0.5 - 0.07), y, z * (t * 0.5 - 0.07)),
					Vector3(s * (t * 0.5 - 0.03), 0.0, z * (t * 0.5 - 0.03)), 0.035, 0.03, 6, under)
	return m.commit()


## A 600 ml brown bottle, the kind that's shared at a table.
static func _bottle_mesh() -> ArrayMesh:
	var m := PropMesh.new()
	var brown := Color(0.28, 0.14, 0.05)
	m.tube(PackedVector3Array([Vector3.ZERO, Vector3.ZERO, Vector3.UP * 0.19, Vector3.UP * 0.25, Vector3.UP * 0.31, Vector3.UP * 0.31]),
			PackedFloat32Array([0.0, 0.039, 0.039, 0.016, 0.015, 0.0]), 7, brown)
	return m.commit()


## Plastic bottle crate, tinted by the instance colour.
static func _crate_mesh() -> ArrayMesh:
	var m := PropMesh.new()
	var s := CRATE_SIZE
	var c := Color.WHITE
	m.block(Vector3(0.0, -s.y * 0.42, 0.0), Vector3(s.x, s.y * 0.16, s.z), c)
	for side: float in [-1.0, 1.0]:
		m.block(Vector3(0.0, 0.0, side * (s.z * 0.5 - 0.01)), Vector3(s.x, s.y, 0.02), c)
		m.block(Vector3(side * (s.x * 0.5 - 0.01), 0.0, 0.0), Vector3(0.02, s.y, s.z), c)
	var dark := Color(0.2, 0.2, 0.2)
	for ix in 3:
		for iz in 2:
			m.block(Vector3((ix - 1.0) * 0.14, s.y * 0.1, (iz - 0.5) * 0.14), Vector3(0.08, s.y * 0.6, 0.08), dark)
	return m.commit()


## Beach umbrella: alternating `color` and white panels on a wooden pole.
static func _umbrella_mesh(color: Color) -> ArrayMesh:
	var m := PropMesh.new()
	var panels := 12
	var top := Vector3.UP * UMBRELLA_HEIGHT
	var rim_y := UMBRELLA_HEIGHT - 0.5
	var white := Tuning.arena_beach.foam_color
	var pole := Tuning.arena_beach.wood_color
	m.rod(Vector3.ZERO, top + Vector3.UP * 0.08, 0.025, 0.02, 6, pole)
	for i in panels:
		var a0 := TAU * i / panels
		var a1 := TAU * (i + 1) / panels
		var r := UMBRELLA_RADIUS
		var p0 := Vector3(cos(a0) * r, rim_y, sin(a0) * r)
		var p1 := Vector3(cos(a1) * r, rim_y, sin(a1) * r)
		var c := color if i % 2 == 0 else white
		m.tri(top, p1, p0, c)
		m.tri(top, p0, p1, c.darkened(0.25))  # seen from below
		var v0 := p0 + Vector3.DOWN * 0.12
		var v1 := p1 + Vector3.DOWN * 0.12
		m.two_sided_quad(v0, v1, p1, p0, c)
	return m.commit()


## Coconut palm: a leaning, tapered trunk and a crown of drooping fronds.
static func _palm_mesh(lean: float, height: float) -> ArrayMesh:
	var b := Tuning.arena_beach
	var m := PropMesh.new()
	var points := PackedVector3Array()
	var radii := PackedFloat32Array()
	var segments := 6
	for i in segments + 1:
		var t := float(i) / segments
		points.append(Vector3(lean * t * t * 1.4, t * height, 0.0))
		radii.append(lerpf(0.26, 0.13, t))
	m.tube(points, radii, 7, b.trunk_color)
	var crown := points[segments]
	var fronds := 11
	for f in fronds:
		var a := TAU * f / fronds + (f % 2) * 0.14
		var dir := Vector3(cos(a), 0.0, sin(a))
		var side := Vector3(-dir.z, 0.0, dir.x)
		var length := 3.4 + (f % 3) * 0.55
		var rise := 0.8 + (f % 2) * 0.55
		var parts := 6
		var shade := b.frond_color.lightened(0.05 * (f % 3))
		for s in parts:
			var t0 := float(s) / parts
			var t1 := float(s + 1) / parts
			var p0 := crown + dir * length * t0 + Vector3.UP * (rise * sin(t0 * 2.4) - t0 * t0 * 1.3)
			var p1 := crown + dir * length * t1 + Vector3.UP * (rise * sin(t1 * 2.4) - t1 * t1 * 1.3)
			var w0 := 0.42 * sin(PI * clampf(t0 * 0.92 + 0.05, 0.0, 1.0))
			var w1 := 0.42 * sin(PI * clampf(t1 * 0.92 + 0.05, 0.0, 1.0))
			var droop := Vector3.DOWN * 0.22
			# Two blades folded along the rib, tips hanging.
			m.two_sided_quad(p0, p1, p1 + side * w1 + droop * t1, p0 + side * w0 + droop * t0, shade)
			m.two_sided_quad(p0, p0 - side * w0 + droop * t0, p1 - side * w1 + droop * t1, p1, shade.darkened(0.12))
	return m.commit()
