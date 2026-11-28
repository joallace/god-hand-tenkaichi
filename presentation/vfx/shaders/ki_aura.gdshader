// Ki charge aura: a flame-shaped shell around the fighter (KiAura's lathe
// mesh: UV.x = around, UV.y = 0 at the feet .. 1 at the pointed top). Flame
// tongues lick upward (vertex), the surface is torn into cel-banded flames
// that thin out toward the top, the centre stays see-through so the body
// reads inside it. fx_power 0..1 grows it in and out.
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, fog_disabled, shadows_disabled;

#include "res://presentation/vfx/shaders/fx_common.gdshaderinc"

instance uniform vec4 fx_color : source_color = vec4(1.0);
instance uniform float fx_power = 1.0;
instance uniform float fx_seed = 0.0;
// Rise speed of the flame pattern (cycles/s).
uniform float rise_speed = 1.6;
// Tongues around the body.
uniform float tongues = 7.0;

void vertex() {
	float h = UV.y;
	float t = TIME * rise_speed;
	float n = fx_noise2_wrap(vec2(UV.x * tongues, h * 2.5 - t * 1.4 + fx_seed), tongues);
	vec3 out_dir = normalize(vec3(VERTEX.x, 0.0, VERTEX.z) + vec3(1e-4, 0.0, 0.0));
	float lick = (n - 0.3) * mix(0.04, 0.32, h);
	VERTEX += out_dir * lick;
	VERTEX.y += max(n - 0.45, 0.0) * h * h * 0.9;
	VERTEX *= mix(0.6, 1.0, fx_power);
}

void fragment() {
	float h = UV.y;
	float t = TIME * rise_speed;
	float facing = abs(dot(NORMAL, VIEW));
	float n = fx_noise2_wrap(vec2(UV.x * tongues * 2.0, h * 4.0 - t * 3.0 + fx_seed), tongues * 2.0) * 0.65
			+ fx_noise2_wrap(vec2(UV.x * tongues * 4.0, h * 8.0 - t * 5.0), tongues * 4.0) * 0.35;
	// Torn flames: holes grow toward the top; fx_power < 1 thins it out.
	float e = n - mix(0.3, 0.78, h) - (1.0 - fx_power) * 0.6 + (1.0 - facing) * 0.3;
	float soft = max(fwidth(e), 1e-4);
	float a = fx_cut(0.0, e, soft);
	a *= smoothstep(0.0, 0.06, h);
	a *= mix(0.12, 0.9, pow(1.0 - facing, 2.0));
	vec3 tint = fx_color.rgb;
	vec3 hot = mix(tint, vec3(1.0), 0.6);
	vec3 col = mix(tint * 0.7, tint * 1.1, fx_cut(0.05, e, soft));
	col = mix(col, hot, fx_cut(0.32, e, soft));
	ALBEDO = col;
	ALPHA = a * fx_color.a;
}
