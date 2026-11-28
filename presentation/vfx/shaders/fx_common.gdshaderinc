// Shared helpers for the effect shaders: cheap hash noise (no textures) and
// the cel banding every effect uses (white-hot core, tint, dark rim), so the
// effects read like the toon-shaded, outlined fighters.

float fx_hash1(float n) {
	return fract(sin(n * 127.1) * 43758.5453);
}

float fx_hash2(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

// Value noise in [0, 1].
float fx_noise2(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	float a = fx_hash2(i);
	float b = fx_hash2(i + vec2(1.0, 0.0));
	float c = fx_hash2(i + vec2(0.0, 1.0));
	float d = fx_hash2(i + vec2(1.0, 1.0));
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

// Noise that wraps every `period` cells on x (around a cylinder / a circle).
float fx_noise2_wrap(vec2 p, float period) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	float x0 = mod(i.x, period);
	float x1 = mod(i.x + 1.0, period);
	float a = fx_hash2(vec2(x0, i.y));
	float b = fx_hash2(vec2(x1, i.y));
	float c = fx_hash2(vec2(x0, i.y + 1.0));
	float d = fx_hash2(vec2(x1, i.y + 1.0));
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

float fx_noise3(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	vec3 u = f * f * (3.0 - 2.0 * f);
	float n = i.x + i.y * 57.0 + i.z * 113.0;
	float a = mix(mix(fx_hash1(n), fx_hash1(n + 1.0), u.x),
			mix(fx_hash1(n + 57.0), fx_hash1(n + 58.0), u.x), u.y);
	float b = mix(mix(fx_hash1(n + 113.0), fx_hash1(n + 114.0), u.x),
			mix(fx_hash1(n + 170.0), fx_hash1(n + 171.0), u.x), u.y);
	return mix(a, b, u.z);
}

// Hard-edged step, `soft` wide (anti-aliased by the caller's fwidth).
float fx_cut(float edge, float x, float soft) {
	return smoothstep(edge - soft, edge + soft, x);
}

// Cel bands from a field `f` (0 = outside edge, 1 = centre): dark-tinted rim
// near the edge, the tint, then a white-hot core above `core`.
vec3 fx_bands(vec3 tint, float f, float core, float rim, float soft) {
	vec3 rim_col = tint * 0.55;
	vec3 hot = mix(tint, vec3(1.0), 0.85);
	vec3 c = mix(rim_col, tint, fx_cut(rim, f, soft));
	return mix(c, hot, fx_cut(core, f, soft));
}
