shader_type canvas_item;

// CALIBRATED FULLSCREEN LOAD — a measurement instrument, not a visual effect.
// Used only by scripts/tools/profile_web.gd; nothing in the game references it.
//
// WHY IT EXISTS. The web build is vsync-locked: the browser drives the main loop
// from requestAnimationFrame, so every frame reads as the refresh interval until
// the frame actually MISSES it. Under that floor, "is rain expensive?" is
// unanswerable — rain on and rain off both measure 16.7 ms.
//
// This shader is the ballast that lifts the whole system OFF the floor. Stack N
// of these rects and the frame goes over budget by a KNOWN, LINEAR amount; the
// slope of frame-time against N prices one fullscreen pass in ms, and with the
// baseline already over budget an A/B of the real layers becomes measurable.
//
// It deliberately MIMICS post_process.gdshader's shape rather than burning ALU
// in a loop: one screen-texture read (which is what actually costs on a tiler —
// each stacked pass forces its own framebuffer copy) plus a few ops. A loop with
// a uniform trip count would price the driver's loop handling instead, and
// unrolls differently per GPU.
//
// It must not CHANGE the picture, or the A/B would be comparing two different
// images: the final COLOR is the screen sampled straight back, and the arithmetic
// is folded in at a weight of exactly zero. `weight` is a uniform, not a
// constant, so no compiler can prove the work dead and strip it — the whole
// measurement depends on the work actually running.
uniform sampler2D screen_texture : hint_screen_texture, filter_nearest;
uniform float weight = 0.0;

void fragment() {
	vec4 src = texture(screen_texture, SCREEN_UV);

	// Representative per-fragment arithmetic. Cheap next to the sample above,
	// which is the point — this is priced as "a fullscreen pass", and a
	// fullscreen pass on this project is dominated by its screen read.
	vec2 p = SCREEN_UV * 2.0 - 1.0;
	float d = dot(p, p);
	vec3 work = src.rgb * (1.0 + d) + vec3(d * 0.5, d * 0.25, d * 0.125);

	COLOR = vec4(src.rgb + work * weight, src.a);
}
