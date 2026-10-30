class_name FxMaterials
extends RefCounted
## Materials for visuals that come and go during a match: hit sparks,
## flashes, shockwaves, afterimages, ki blasts, beams, the ki aura.
##
## Godot generates one shader per StandardMaterial3D feature combination
## (shading mode, transparency, cull, emission on/off...), shares it between
## the materials that use it and frees it, pipelines included, as soon as the
## last one goes away. A material that lives only as long as its effect would
## recompile its shader every time the effect comes back: a frame hitch on
## every hit, teleport and blast. So every effect material is a copy of a
## template kept here for the whole session (copies share its shader), and
## warm_up() draws each template once at match start so the first hit
## doesn't compile either.
##
## On a live material, vary values (colors, emission energy), never feature
## flags (emission_enabled, transparency, ...): a flag change swaps shaders.

enum Kind {
	TRANSLUCENT,         ## unshaded alpha, both faces (shockwaves, afterimages)
	TRANSLUCENT_ON_TOP,  ## same, drawn through bodies (hit flashes, sparks)
	FLASH,               ## unshaded alpha, front faces (vanish/reappear sphere)
	GLOW,                ## unshaded opaque + emission (ki blasts)
	BEAM,                ## unshaded alpha + emission (beam supers)
	AURA,                ## unshaded additive, both faces (ki charge aura)
}

static var _templates: Dictionary = {}  # Kind -> StandardMaterial3D


## A new material of `kind` (sharing the template's shader), tinted `color`.
static func make(kind: Kind, color: Color = Color.WHITE) -> StandardMaterial3D:
	var t := template(kind)
	var m := t.duplicate() as StandardMaterial3D
	# duplicate() skips properties the inspector hides, emission_enabled on an
	# unshaded material included: restore it so the copy keeps t's shader.
	if t.emission_enabled:
		m.emission_enabled = true
	m.albedo_color = color
	return m


## The session-lifetime template of `kind` (read only: copy it with make()).
static func template(kind: Kind) -> StandardMaterial3D:
	var m: StandardMaterial3D = _templates.get(kind)
	if m == null:
		m = _build(kind)
		_templates[kind] = m
	return m


## Draw every template once under `parent` (a tiny, never-culled mesh each,
## at its origin) for Tuning.vfx.material_warmup_frames frames, so shaders
## and pipelines compile while the match loads instead of on the first hit.
static func warm_up(parent: Node3D) -> void:
	var v := Tuning.vfx
	var holder := Node3D.new()
	holder.name = "MaterialWarmUp"
	parent.add_child(holder)
	var mesh := SphereMesh.new()
	mesh.radius = v.material_warmup_radius
	mesh.height = v.material_warmup_radius * 2.0
	var half := Vector3.ONE * v.material_warmup_cull_size * 0.5
	for kind: Kind in Kind.values():
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		mi.material_override = template(kind)
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.custom_aabb = AABB(-half, half * 2.0)
		holder.add_child(mi)
	var tree := parent.get_tree()
	for i in v.material_warmup_frames:
		await tree.process_frame
	if is_instance_valid(holder):
		holder.queue_free()


static func _build(kind: Kind) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	match kind:
		Kind.TRANSLUCENT, Kind.TRANSLUCENT_ON_TOP:
			m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			m.blend_mode = BaseMaterial3D.BLEND_MODE_MIX
			m.cull_mode = BaseMaterial3D.CULL_DISABLED
			m.no_depth_test = kind == Kind.TRANSLUCENT_ON_TOP
			m.render_priority = 1 if kind == Kind.TRANSLUCENT_ON_TOP else 0
		Kind.FLASH:
			m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		Kind.GLOW:
			m.emission_enabled = true
		Kind.BEAM:
			m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			m.emission_enabled = true
		Kind.AURA:
			m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
			m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m
