// Ki motes rising around a charging fighter: a MultiMesh of 1x1 quads,
// each placed and animated here from its INSTANCE_ID and TIME (no per-frame
// CPU work). Each is a thin vertical streak billboarded to the camera,
// rising from the feet and fading in and out. Model space = fighter's feet.
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, skip_vertex_transform, fog_disabled, shadows_disabled;

#include "res://presentation/vfx/shaders/fx_common.gdshaderinc"

instance uniform vec4 fx_color : source_color = vec4(1.0);
instance uniform float fx_power = 1.0;
instance uniform float fx_seed = 0.0;
// Column the motes rise in (model space, m), their size (m) and speed (1/s).
uniform float height = 2.6;
uniform float radius_min = 0.35;
uniform float radius_max = 0.85;
uniform vec2 mote_size = vec2(0.06, 0.42);
uniform vec2 rise_rate = vec2(0.7, 1.4);

varying float v_fade;

void vertex() {
	float id = float(INSTANCE_ID) + fx_seed * 101.0;
	float rate = mix(rise_rate.x, rise_rate.y, fx_hash1(id * 3.1));
	float phase = fract(TIME * rate + fx_hash1(id * 1.3));
	float ang = fx_hash1(id * 7.7) * 6.28318530718 + TIME * 0.6;
	float rad = mix(radius_min, radius_max, fx_hash1(id * 5.3)) * (1.0 - phase * 0.35);
	vec3 c = vec3(cos(ang) * rad, phase * height, sin(ang) * rad);
	vec3 vc = (MODELVIEW_MATRIX * vec4(c, 1.0)).xyz;
	float s = mix(0.6, 1.2, fx_hash1(id * 9.1)) * fx_power;
	VERTEX = vc + vec3(VERTEX.x * mote_size.x * s, VERTEX.y * mote_size.y * s, 0.0);
	v_fade = sin(phase * 3.14159265);
}

void fragment() {
	vec2 p = vec2(UV.x * 2.0 - 1.0, 1.0 - UV.y * 2.0);
	float f = 1.0 - (abs(p.x) + abs(p.y) * 0.5) - (1.0 - v_fade) * 0.6;
	float soft = max(fwidth(f), 1e-4);
	ALBEDO = fx_bands(fx_color.rgb, f, 0.3, 0.05, soft);
	ALPHA = fx_cut(0.0, f, soft) * fx_color.a;
}
