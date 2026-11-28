// Translucent ragged flame around a ki energy core: see ki_energy.gdshaderinc.
shader_type spatial;
render_mode unshaded, cull_back, depth_draw_never, fog_disabled, shadows_disabled;

#define ENERGY_SHELL
#include "res://presentation/vfx/shaders/ki_energy.gdshaderinc"
