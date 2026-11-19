shader_type spatial;
// The second pass of cc_hair: blends the soft strand ends (opacity below the
// solid pass's cutoff) over what is already drawn. It writes no depth and
// casts no shadow; the solid pass behind it does both, so its own sorting
// errors are confined to thin, faint fringes.
render_mode cull_disabled, depth_draw_never, blend_mix, shadows_disabled;

#include "cc_hair.gdshaderinc"

uniform float cutoff = 0.5;

void fragment() {
	HAIR_SURFACE(UV);
	float a = hair_alpha(UV);
	if (a >= cutoff || a < 0.02) {
		discard;
	}
	ALPHA = a;
}
