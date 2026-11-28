class_name FxMaterials
extends RefCounted
## Materials for visuals that come and go during a match: hit sparks,
## flashes, shockwaves, afterimages, ki blasts, beams, the ki aura.
##
## Godot compiles a shader (and its pipelines) per material feature set and
## frees it once the last material using it goes away; an effect that brought
## its own material would recompile on every hit, teleport and blast (a frame
## hitch). So:
## - The effect shaders (Fx: sprites, bursts, ki energy, aura, motes) are ONE shared
##   ShaderMaterial each for the whole session (shared()). Everything that
##   varies per effect (colour, shape, progress, flow...) is an `instance
##   uniform`, set with GeometryInstance3D.set_instance_shader_parameter:
##   no material is built per effect at all.
## - StandardMaterial3D effects (Kind: afterimage ghosts) keep a template of
##   every kind alive (its shader with it) and make() builds copies with the
##   template's exact flags, so they share that shader.
## - warm_up() draws every template and shared material once at match start
##   so the first hit doesn't compile either.
##
## make() builds fresh instead of duplicate(): on the web build (WASM)
## duplicate() walks every material property, ~15x slower than new + sets
## (0.32 vs 0.02 ms each), enough to drop a frame on a heavy hit.
##
## On a live material, vary values (colors, emission energy), never feature
## flags (emission_enabled, transparency, ...): a flag change swaps shaders.

enum Kind {
	TRANSLUCENT,  ## unshaded alpha, both faces (afterimages)
}

## Shared shader materials (session lifetime, per-effect values are instance uniforms).
enum Fx {
	SPRITE,         ## any 2D effect shape on a quad (Shape, Facing), depth tested
	BURST,          ## 3D effect mesh: hit flash spheres, debris chunks
	ENERGY_CORE,    ## opaque white-hot ki core (blasts, beams)
	ENERGY_SHELL,   ## translucent ragged flame around a core
	AURA,           ## ki charge flame shell (KiAura's lathe mesh)
	MOTES,          ## rising ki streaks (MultiMesh of quads, animated in the shader)
}

## Sprite shapes: SHAPE_* in shaders/fx_sprite.gdshaderinc.
enum Shape { RING, STREAK, PUFF, SWIRL, FLARE, TAIL }
## Sprite facing: FACE_* in shaders/fx_sprite.gdshaderinc.
enum Facing { CAMERA, NODE, AXIS }

const SHADER_PATHS := {
	Fx.SPRITE: "res://presentation/vfx/shaders/fx_sprite.gdshader",
	Fx.BURST: "res://presentation/vfx/shaders/fx_burst.gdshader",
	Fx.ENERGY_CORE: "res://presentation/vfx/shaders/ki_energy_core.gdshader",
	Fx.ENERGY_SHELL: "res://presentation/vfx/shaders/ki_energy_shell.gdshader",
	Fx.AURA: "res://presentation/vfx/shaders/ki_aura.gdshader",
	Fx.MOTES: "res://presentation/vfx/shaders/ki_motes.gdshader",
}

static var _templates: Dictionary = {}  # Kind -> StandardMaterial3D
static var _shared: Dictionary = {}  # Fx -> ShaderMaterial
static var _quad: QuadMesh


## A new material of `kind` (sharing the template's shader), tinted `color`.
static func make(kind: Kind, color: Color = Color.WHITE) -> StandardMaterial3D:
	template(kind)  # keeps the shader alive
	var m := _build(kind)
	m.albedo_color = color
	return m


## The session-lifetime template of `kind` (read only: get copies from make()).
static func template(kind: Kind) -> StandardMaterial3D:
	var m: StandardMaterial3D = _templates.get(kind)
	if m == null:
		m = _build(kind)
		_templates[kind] = m
	return m


## The one material every effect of `fx` uses (never modify it: set
## instance uniforms on the mesh instead).
static func shared(fx: Fx) -> ShaderMaterial:
	var m: ShaderMaterial = _shared.get(fx)
	if m == null:
		m = ShaderMaterial.new()
		m.shader = load(SHADER_PATHS[fx])
		_shared[fx] = m
	return m


## The 1x1 quad every sprite draws on.
static func quad() -> QuadMesh:
	if _quad == null:
		_quad = QuadMesh.new()
	return _quad


## A sprite mesh instance (not yet in the tree) drawing `shape`.
static func sprite(shape: Shape, color: Color, facing: Facing = Facing.CAMERA) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = quad()
	mi.material_override = shared(Fx.SPRITE)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.set_instance_shader_parameter(&"fx_shape", shape)
	mi.set_instance_shader_parameter(&"fx_facing", facing)
	mi.set_instance_shader_parameter(&"fx_color", color)
	return mi


## Draw every template and shared material once under `parent` (a tiny,
## never-culled mesh each, at its origin) for Tuning.vfx.material_warmup_frames
## frames, so shaders and pipelines compile while the match loads instead of
## on the first hit.
static func warm_up(parent: Node3D) -> void:
	var v := Tuning.vfx
	var holder := Node3D.new()
	holder.name = "MaterialWarmUp"
	parent.add_child(holder)
	var mesh := SphereMesh.new()
	mesh.radius = v.material_warmup_radius
	mesh.height = v.material_warmup_radius * 2.0
	var half := Vector3.ONE * v.material_warmup_cull_size * 0.5
	var mats: Array[Material] = []
	for kind: Kind in Kind.values():
		mats.append(template(kind))
	for fx: Fx in Fx.values():
		mats.append(shared(fx))
	for m in mats:
		var gi: GeometryInstance3D
		if m == shared(Fx.MOTES):
			var mm := MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_3D
			mm.mesh = mesh
			mm.instance_count = 1
			var mmi := MultiMeshInstance3D.new()
			mmi.multimesh = mm
			gi = mmi
		else:
			var mi := MeshInstance3D.new()
			mi.mesh = mesh
			gi = mi
		gi.material_override = m
		gi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		gi.custom_aabb = AABB(-half, half * 2.0)
		holder.add_child(gi)
	var tree := parent.get_tree()
	for i in v.material_warmup_frames:
		await tree.process_frame
	if is_instance_valid(holder):
		holder.queue_free()


## Number of meshes warm_up() draws (tests).
static func warm_up_count() -> int:
	return Kind.size() + Fx.size()


static func _build(kind: Kind) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	match kind:
		Kind.TRANSLUCENT:
			m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			m.blend_mode = BaseMaterial3D.BLEND_MODE_MIX
			m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m
