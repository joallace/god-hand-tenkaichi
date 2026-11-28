// Body of the effect sprite shaders (fx_sprite / fx_sprite_on_top): one quad
// draws any 2D effect shape, picked and animated per instance (instance
// uniforms), so every pooled effect mesh shares one material and one shader.
// Shapes are cel-banded fields (white core, tint, dark rim) with hard
// anti-aliased edges, matching the toon fighters. Needs the quad mesh
// (QuadMesh, size 1x1) and render_mode skip_vertex_transform.

#include "res://presentation/vfx/shaders/fx_common.gdshaderinc"

// FxMaterials.Shape must match these.
const int SHAPE_STAR = 0;        // impact burst: spiky star, collapses inward
const int SHAPE_RING = 1;        // shock ring, expands and thins
const int SHAPE_ORB = 2;         // round flash, dissolves from the edge
const int SHAPE_STREAK = 3;      // spark: thin diamond along fx_dir
const int SHAPE_PUFF = 4;        // dust cloud, lit from above, no white core
const int SHAPE_SPEEDLINES = 5;  // radial lines flying outward
const int SHAPE_SWIRL = 6;       // looping ki ring on the ground (uses TIME)
const int SHAPE_FLARE = 7;       // spinning 8-point glint (uses TIME)
const int SHAPE_TAIL = 8;        // comet tail behind fx_dir, flickering

// FxMaterials.Facing.
const int FACE_CAMERA = 0;  // billboard (node rotation ignored, scale kept)
const int FACE_NODE = 1;    // the quad as placed (e.g. lying on the floor)
const int FACE_AXIS = 2;    // long axis (local Y) along fx_dir, turned to the camera

instance uniform vec4 fx_color : source_color = vec4(1.0);
instance uniform float fx_progress = 0.0;
instance uniform int fx_shape = 0;
instance uniform int fx_facing = 0;
instance uniform float fx_seed = 0.0;
instance uniform float fx_spin = 0.0;
instance uniform vec3 fx_dir = vec3(0.0, 1.0, 0.0);


void vertex() {
	float sx = length(MODEL_MATRIX[0].xyz);
	float sy = length(MODEL_MATRIX[1].xyz);
	if (fx_facing == FACE_CAMERA) {
		vec3 c = (MODELVIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
		VERTEX = c + vec3(VERTEX.x * sx, VERTEX.y * sy, 0.0);
	} else if (fx_facing == FACE_AXIS) {
		vec3 c = MODEL_MATRIX[3].xyz;
		vec3 y = normalize(fx_dir + vec3(0.0, 1e-5, 0.0));
		vec3 to_cam = INV_VIEW_MATRIX[3].xyz - c;
		vec3 x = cross(y, to_cam);
		x = length(x) > 1e-4 ? normalize(x) : normalize(cross(y, vec3(0.0, 0.0, 1.0)) + vec3(1e-4, 0.0, 0.0));
		vec3 w = c + x * VERTEX.x * sx + y * VERTEX.y * sy;
		VERTEX = (VIEW_MATRIX * vec4(w, 1.0)).xyz;
	} else {
		VERTEX = (MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	}
}

vec2 rot2(vec2 p, float a) {
	float c = cos(a);
	float s = sin(a);
	return vec2(c * p.x - s * p.y, s * p.x + c * p.y);
}

void fragment() {
	vec2 p = vec2(UV.x * 2.0 - 1.0, 1.0 - UV.y * 2.0);
	float pr = clamp(fx_progress, 0.0, 1.0);
	float seed = fx_seed;
	float f = -1.0;      // field: > 0 inside, 1 at the centre
	float core = 0.6;    // field above this is white-hot
	float rim = 0.14;    // field below this is the dark rim
	bool lit = false;    // PUFF: shaded from above instead of a hot core
	if (fx_shape == SHAPE_STAR) {
		vec2 q = rot2(p, seed * TAU + fx_spin * TIME);
		float r = length(q);
		float n = 7.0 + floor(seed * 5.0);
		float k = (atan(q.y, q.x) / TAU + 0.5) * n;
		float cell = floor(k + 0.5);
		float tri = 1.0 - abs(fract(k + 0.5) - 0.5) * 2.0;
		float len = mix(0.5, 1.0, fx_hash1(cell + seed * 37.0));
		float R = mix(0.3, len, pow(tri, 2.2));
		f = 1.0 - r / R;
		f -= pr * pr * 1.05;
		core = 0.42 + pr * 0.25;
	} else if (fx_shape == SHAPE_RING) {
		float r = length(p);
		float a01 = atan(p.y, p.x) / TAU + 0.5;
		float e = 1.0 - pow(1.0 - pr, 3.0);
		float rr = mix(0.22, 0.9, e);
		float thick = (0.09 * (1.0 - pr) + 0.01) * (0.55 + 0.9 * fx_noise2_wrap(vec2(a01 * 9.0, seed * 7.0), 9.0));
		f = 1.0 - abs(r - rr) / thick;
		core = 0.65;
		rim = 0.2;
	} else if (fx_shape == SHAPE_ORB) {
		float r = length(p);
		float a01 = atan(p.y, p.x) / TAU + 0.5;
		float edge = 0.88 + 0.12 * fx_noise2_wrap(vec2(a01 * 7.0, seed * 5.0 + pr * 3.0), 7.0);
		f = 1.0 - r / edge;
		f -= pr * (0.55 + 0.6 * fx_noise2(p * 3.5 + seed * 11.0));
		core = 0.5;
	} else if (fx_shape == SHAPE_STREAK) {
		f = 1.0 - (abs(p.x) * 2.6 + abs(p.y));
		f -= pr * 0.85;
		core = 0.4;
		rim = 0.1;
	} else if (fx_shape == SHAPE_PUFF) {
		float r = length(p);
		float a01 = atan(p.y, p.x) / TAU + 0.5;
		float R = 0.7 + 0.3 * fx_noise2_wrap(vec2(a01 * 6.0, seed * 9.0 + pr * 1.5), 6.0);
		f = 1.0 - r / R;
		f -= pr * (0.6 + 0.5 * fx_noise2(p * 4.0 + seed * 13.0));
		lit = true;
	} else if (fx_shape == SHAPE_SPEEDLINES) {
		float r = length(p);
		float a01 = atan(p.y, p.x) / TAU + 0.5;
		float cells = 40.0;
		float cell = floor(a01 * cells);
		float h = fx_hash1(cell + seed * 53.0);
		float on = step(0.45, h);
		float rin = mix(0.18, 0.75, pr) + h * 0.12;
		float len = 0.2 + 0.35 * fx_hash1(cell * 1.7 + seed);
		float along = (r - rin) / len;
		float w = 0.32 * (1.0 - pr * 0.7) * (1.0 - clamp(along, 0.0, 1.0));
		float across = abs(fract(a01 * cells) - 0.5);
		bool inside = on > 0.5 && along >= 0.0 && along <= 1.0;
		f = inside ? 1.0 - across / max(w, 1e-3) : -1.0;
		core = 0.35;
	} else if (fx_shape == SHAPE_SWIRL) {
		float r = length(p);
		float a01 = atan(p.y, p.x) / TAU + 0.5;
		float t = TIME * fx_spin;
		float n = fx_noise2_wrap(vec2(a01 * 12.0 + t * 3.0, t * 1.5 + seed * 4.0), 12.0);
		float ring = 1.0 - abs(r - 0.8) / (0.035 + 0.11 * n);
		float dash = step(0.45, fract(a01 * 14.0 - t * 0.6));
		float inner = (1.0 - abs(r - 0.55) / 0.03) * dash - (1.0 - dash);
		f = max(ring, inner);
		core = 0.7;
	} else if (fx_shape == SHAPE_FLARE) {
		vec2 q = rot2(p, seed * TAU + fx_spin * TIME);
		q *= 1.0 + 0.12 * sin(TIME * 23.0 + seed * 40.0);
		float r = length(q);
		float cross1 = 1.0 - r - min(abs(q.x), abs(q.y)) * 7.0;
		vec2 d = rot2(q, TAU * 0.125);
		float cross2 = 1.0 - r * 1.7 - min(abs(d.x), abs(d.y)) * 8.0;
		f = max(max(cross1, cross2), 0.32 - r);
		f -= pr;
		core = 0.35;
	} else if (fx_shape == SHAPE_TAIL) {
		float t = clamp((1.0 - p.y) * 0.5, 0.0, 1.0);  // 0 at the head, 1 at the end
		float flick = 0.7 + 0.45 * fx_noise2(vec2(t * 5.0 - TIME * 14.0, seed * 9.0 + p.x * 2.0));
		float w = pow(1.0 - t, 0.8) * flick;
		f = (1.0 - abs(p.x) / max(w, 1e-3)) * (1.0 - t * 0.85) - pr;
		core = 0.45;
	}
	float soft = max(fwidth(f), 1e-4);
	float alpha = fx_cut(0.0, f, soft * 0.75);
	vec3 tint = fx_color.rgb;
	vec3 col;
	if (lit) {
		float light = step(0.0, p.y * 0.8 + p.x * 0.3 + 0.05 * sin(seed * 20.0));
		col = mix(tint * 0.86, tint * 1.05, light);
		col = mix(tint * 0.78, col, fx_cut(rim, f, soft));
	} else {
		col = fx_bands(tint, f, core, rim, soft);
	}
	ALBEDO = col;
	ALPHA = alpha * fx_color.a;
}
