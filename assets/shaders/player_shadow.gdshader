shader_type canvas_item;

// Shadow cast eastward (screen-right) by rotating the sprite 90° CCW
// and squashing to simulate a ground-plane projection.

uniform vec4 shadow_color : source_color = vec4(0.0, 0.0, 0.05, 1.0);
uniform float squash : hint_range(0.1, 1.0) = 0.35;
uniform float visual_y_offset = 0.0;

void vertex() {
	vec2 v = VERTEX;
	VERTEX.x = round(-v.y - 2.0);
	VERTEX.y = round(-v.x * squash - 2.0 + visual_y_offset);
}
 
void fragment() {
	vec4 tex = texture(TEXTURE, UV);
	COLOR = vec4(shadow_color.rgb, tex.a*0.5);
}
