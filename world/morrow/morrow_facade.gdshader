shader_type spatial;

// MorrowCity's walls: one wall texture, with windows drawn on it in bays and
// storeys (no window geometry). MorrowCity writes, per vertex:
//   UV     x metres along the wall from its corner, y metres above the floor
//   UV2    x the building's storeys, y the wall's length in metres
//   COLOR  rgb the building's tint, a 1 on a downtown street front (shops)
// Each wall is cut into as many 3 m bays as fit, stretched to fill it, so a
// window never straddles a corner. The ground floor is 4.5 m, the rest 3.5;
// above the top storey (parapets, gable ends) and below the floor (the
// foundation on a slope) there are no windows.

uniform sampler2D wall_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D wall_normal : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
// Repeats per metre.
uniform float wall_tile = 0.4;
uniform float bay = 3.0;
uniform float ground_floor = 4.5;
uniform float storey = 3.5;
uniform vec3 glass : source_color = vec3(0.06, 0.08, 0.1);
uniform vec3 frame : source_color = vec3(0.78, 0.76, 0.7);
uniform vec3 shop_glass : source_color = vec3(0.12, 0.11, 0.09);

// Signed distance to a box: < 0 inside.
float box(vec2 p, vec2 centre, vec2 half_size) {
	vec2 d = abs(p - centre) - half_size;
	return max(d.x, d.y);
}

void fragment() {
	float along = UV.x;
	float h = UV.y;
	vec2 t = vec2(along, h) * wall_tile;
	vec3 col = texture(wall_albedo, t).rgb * COLOR.rgb;
	vec3 nrm = texture(wall_normal, t).rgb;
	float rough = 0.9;

	float storeys = UV2.x;
	float len = UV2.y;
	float bays = floor(len / bay);
	if (h < 0.0) {
		col *= 0.62;
	} else if (bays >= 1.0) {
		float bw = len / bays;
		float x = mod(along, bw) - bw * 0.5;
		float s = 0.0;
		float local = h;
		float tall = ground_floor;
		if (h >= ground_floor) {
			s = 1.0 + floor((h - ground_floor) / storey);
			local = h - ground_floor - (s - 1.0) * storey;
			tall = storey;
		}
		if (s < storeys) {
			bool shop = s < 0.5 && COLOR.a > 0.5;
			vec2 half_size = shop ? vec2(bw * 0.5 - 0.3, 1.55) : (s < 0.5 ? vec2(0.5, 1.05) : vec2(0.55, 0.8));
			float sill = shop ? 0.45 : (s < 0.5 ? 0.9 : 0.95);
			float d = box(vec2(x, local), vec2(0.0, sill + half_size.y), half_size);
			float px = fwidth(local) + fwidth(along);
			float in_frame = 1.0 - smoothstep(-px, px, d);
			float in_glass = 1.0 - smoothstep(-px, px, d + 0.1);
			col = mix(col, frame, in_frame);
			col = mix(col, shop ? shop_glass : glass, in_glass);
			rough = mix(rough, 0.12, in_glass);
			nrm = mix(nrm, vec3(0.5, 0.5, 1.0), in_frame);
			// A string course under each storey's ceiling.
			col *= 1.0 - 0.18 * smoothstep(tall - 0.3, tall - 0.25, local) * (1.0 - in_frame);
		}
	}
	ALBEDO = col;
	ROUGHNESS = rough;
	NORMAL_MAP = nrm;
}
