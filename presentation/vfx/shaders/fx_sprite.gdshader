// Effect sprites drawn with depth (shock rings, dust, trails): see fx_sprite.gdshaderinc.
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, skip_vertex_transform, fog_disabled, shadows_disabled;

#include "res://presentation/vfx/shaders/fx_sprite.gdshaderinc"
