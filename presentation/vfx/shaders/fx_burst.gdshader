// 3D effect meshes (hit flash spheres, debris chunks): cel bands by how
// much a face looks at the camera (white-hot facing the camera, the tint,
// a darker rim), dissolving through noise as fx_progress goes 0 -> 1. One
// shared material; values per instance (VfxManager pools the meshes).
// fx_pull (m) slides the mesh toward the camera without changing its size
// on screen, so a burst isn't swallowed by the body it hits but still hides
// behind anyone standing in front.
shader_type spatial;
render_mode unshaded, cull_back, depth_draw_never, skip_vertex_transform, fog_disabled, shadows_disabled;

#include "res://presentation/vfx/shaders/fx_common.gdshaderinc"

instance uniform vec4 fx_color : source_color = vec4(1.0);
instance uniform float fx_progress = 0.0;
instance uniform float fx_seed = 0.0;
instance uniform float fx_pull = 0.0;
// Field above which a face goes white-hot (> 1 = never: debris keeps its colour).
instance uniform float fx_core = 0.62;

varying vec3 v_local;

void vertex() {
	v_local = VERTEX;
	vec3 c = (MODELVIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	float d = length(c);
	float k = max(d - fx_pull, min(d, 0.1)) / max(d, 1e-4);
	VERTEX = (MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).xyz * k;
	NORMAL = normalize((MODELVIEW_NORMAL_MATRIX * NORMAL));
}

void fragment() {
	float facing = clamp(abs(dot(NORMAL, VIEW)), 0.0, 1.0);
	float pr = clamp(fx_progress, 0.0, 1.0);
	float n = fx_noise3(v_local * 4.0 + vec3(fx_seed * 31.0));
	float f = 0.2 + 0.8 * facing - pr * (0.55 + 0.75 * n);
	float soft = max(fwidth(f), 1e-4);
	ALBEDO = fx_bands(fx_color.rgb, f, fx_core - pr * 0.25, 0.14, soft);
	ALPHA = fx_cut(0.0, f, soft) * fx_color.a;
}
