// Body of the ki energy shaders (ki blasts, beams): ki_energy_core (opaque
// white-hot core with a tinted, dark-rimmed edge and streaming bright
// bands) and ki_energy_shell (#define ENERGY_SHELL: translucent ragged flame
// around it). Noise runs in world space, streaming along -fx_flow, so beam
// segments join without seams. Per instance: tint, flow, wobble, seed.

#include "res://presentation/vfx/shaders/fx_common.gdshaderinc"

instance uniform vec4 fx_color : source_color = vec4(1.0);
// Travel direction * stream speed (m/s); noise scrolls against it.
instance uniform vec3 fx_flow = vec3(0.0);
// Shell only: vertex wobble (m) and noise frequency (1/m).
instance uniform float fx_wobble = 0.05;
instance uniform float fx_freq = 3.0;
instance uniform float fx_seed = 0.0;

varying vec3 v_world;

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
#ifdef ENERGY_SHELL
	vec3 q = v_world * fx_freq - fx_flow * TIME * 1.5 + vec3(fx_seed * 17.0, TIME * 3.0, 0.0);
	VERTEX += NORMAL * (fx_noise3(q) - 0.35) * fx_wobble;
#endif
}

void fragment() {
	float facing = clamp(dot(NORMAL, VIEW), 0.0, 1.0);
	vec3 tint = fx_color.rgb;
	vec3 q = v_world * fx_freq - fx_flow * TIME + vec3(fx_seed * 17.0, 0.0, 0.0);
	float n = fx_noise3(q) * 0.65 + fx_noise3(q * 2.3 + 7.0) * 0.35;
#ifdef ENERGY_SHELL
	// Visible toward the silhouette, torn up by the noise: a flame edge.
	float e = (1.0 - facing) - 0.2 - 0.55 * n;
	float soft = max(fwidth(e), 1e-4);
	ALPHA = fx_cut(0.0, e, soft) * fx_color.a * (0.45 + 0.5 * (1.0 - facing));
	ALBEDO = mix(tint * 1.1, tint * 0.7, fx_cut(0.22, e, soft));
#else
	// White-hot centre, a wide tint band and a thin dark rim; bright streaks flow.
	float f = facing * facing + (n - 0.5) * 0.45;
	float soft = max(fwidth(f), 1e-4);
	ALBEDO = fx_bands(tint, f, 0.55, 0.1, soft);
#endif
}
