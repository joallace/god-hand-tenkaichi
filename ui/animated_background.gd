class_name AnimatedBackground
extends ColorRect
## Cheap full-screen animated backdrop: orange/blue rotating energy burst (single canvas shader, no textures).

const SHADER_CODE := """
shader_type canvas_item;
uniform vec4 col_a : source_color = vec4(1.0, 0.55, 0.08, 1.0);
uniform vec4 col_b : source_color = vec4(0.10, 0.32, 0.85, 1.0);
uniform vec4 col_dark : source_color = vec4(0.04, 0.09, 0.28, 1.0);
uniform float speed = 0.25;
uniform float aspect = 1.777;

void fragment() {
	vec2 p = (UV - vec2(0.5, 0.55)) * vec2(aspect, 1.0);
	float r = length(p);
	float a = atan(p.y, p.x);
	float t = TIME * speed;
	float rays = smoothstep(0.35, 0.95, sin(a * 14.0 + t * 3.0) * 0.5 + 0.5);
	float rays2 = smoothstep(0.6, 1.0, sin(a * 7.0 - t * 2.0) * 0.5 + 0.5);
	float glow = exp(-r * 2.6);
	vec3 c = mix(col_dark.rgb, col_b.rgb, clamp(1.0 - r * 0.9, 0.0, 1.0));
	c = mix(c, col_a.rgb, rays * glow * 0.85 + rays2 * glow * 0.35);
	c += col_a.rgb * glow * (0.35 + 0.1 * sin(TIME * 2.0));
	c *= 1.0 - smoothstep(0.6, 1.3, r) * 0.6;
	COLOR = vec4(c, 1.0);
}
"""


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var u := UiTheme.tuning()
	var sh := Shader.new()
	sh.code = SHADER_CODE
	var m := ShaderMaterial.new()
	m.shader = sh
	m.set_shader_parameter("col_a", u.color_orange)
	m.set_shader_parameter("col_b", u.color_blue)
	m.set_shader_parameter("col_dark", u.color_blue_dark)
	m.set_shader_parameter("speed", u.background_speed)
	material = m
	resized.connect(_on_resized)
	_on_resized()


func _on_resized() -> void:
	if size.y > 0.0:
		(material as ShaderMaterial).set_shader_parameter("aspect", size.x / size.y)
