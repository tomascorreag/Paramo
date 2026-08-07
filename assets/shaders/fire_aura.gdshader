shader_type canvas_item;
render_mode blend_add;

// Screen-edge "aura" pointing toward OFF-SCREEN fires. A warm glow hugs the
// border in the direction of any fire the camera can't currently see, so the
// player feels a fire burning just past the frame. Driven entirely by a tiny 1D
// texture the CPU rebuilds each frame (scripts/vfx/fire_aura_overlay.gd).
//
// The shader has NO knowledge of individual fires. fire_aura_overlay bins every
// off-screen fire into `aura_tex`: a 1px-tall strip indexed by BEARING from
// screen centre (u = angle / TAU + 0.5, wrapping at the ±PI seam via
// repeat_enable). texture(aura_tex, ...).r is the aggregated weight for that
// direction — a fire's intensity × how close it is to the edge, summed across
// every fire pointing that way. That is why an arbitrary number of fires costs
// one texture fetch: they were already merged on the CPU.
//
// Rendered on a root CanvasLayer ABOVE post_process (UILayers.FIRE_AURA). Above
// the grade on purpose: the post-process vignette darkens the screen edges, i.e.
// exactly where this draws — grading it would cancel the effect. blend_add so it
// reads as emitted light bleeding in, not a coloured film.

// 1D angular weight strip (BINS × 1, R32F). repeat_enable wraps the ±PI seam;
// filter_linear smooths between bins so the glow doesn't band.
uniform sampler2D aura_tex : repeat_enable, filter_linear;

// Viewport aspect (width / height). The bearing is aspect-corrected so a fire
// off the RIGHT edge lights the right edge (and not, on a wide screen, a point
// skewed toward a corner). The CPU deposits with the SAME correction — the two
// must agree or the glow lands off-direction.
uniform float aspect = 1.777;

// Size of one LOW-RES texel in this rect's 0..1 UV (= N / window_size, set by the
// CPU from DisplayManager.current_scale). This rect draws at full monitor res —
// above post-process, outside the low-res SubViewport — so without this it would
// bloom smoothly at monitor-pixel resolution and clash with the pixel-art world.
// We snap UV to this grid before doing ANY maths, so the whole aura (bearing,
// colour, band edge) resolves in chunky texels locked to the terrain's grid.
uniform vec2 texel = vec2(0.0);

// Fire ramp: faint edges read red (P05), strong edges read orange (P04) — a
// red->orange ramp with no yellow, so the aura reads as warm firelight bleeding
// past the frame rather than a bright sodium glow.
uniform vec3 color_lo : source_color = vec3(0.710, 0.349, 0.271); // P05 #B55945
uniform vec3 color_hi : source_color = vec3(0.922, 0.588, 0.380); // P04 #EB9661

// Overall brightness of the emitted glow.
uniform float strength : hint_range(0.0, 3.0) = 0.7;
// How deep the glow reaches inward from the edge, at the FAINTEST (min) and
// STRONGEST (max) weight. A bigger/closer fire pushes the band further in — the
// "size proportional to proximity/intensity" half of the brief.
uniform float min_thickness : hint_range(0.0, 0.5) = 0.04;
uniform float max_thickness : hint_range(0.0, 0.8) = 0.18;

// TAU / PI are built into the Godot shading language — do not redefine them.

void fragment() {
	// Snap UV to the low-res texel grid (block centre) so everything downstream —
	// bearing, borderness, band edge — steps in whole terrain texels instead of
	// smooth monitor pixels. texel == 0 (unset) disables the snap, leaving the old
	// smooth behaviour as a safe fallback.
	vec2 puv = UV;
	if (texel.x > 0.0 && texel.y > 0.0) {
		puv = (floor(UV / texel) + 0.5) * texel;
	}

	// Bearing of this fragment from screen centre (aspect-corrected, y down).
	vec2 d = puv - vec2(0.5);
	d.x *= aspect;
	float ang = atan(d.y, d.x);        // -PI..PI
	float u = ang / TAU + 0.5;         // 0..1, wraps via repeat_enable
	float v = texture(aura_tex, vec2(u, 0.5)).r;

	// Borderness: 0 at centre, 1 at the nearest screen edge. max() (not min())
	// so the level set at a given b is a rectangle hugging all four edges — the
	// angular weight `v` is what localises the glow to the fire's direction.
	float b = max(abs(puv.x - 0.5), abs(puv.y - 0.5)) * 2.0;

	float vc = clamp(v, 0.0, 1.0);
	float thickness = mix(min_thickness, max_thickness, vc);
	float band = smoothstep(1.0 - thickness, 1.0, b);

	// v (unclamped) drives brightness so stacked fires can glow past 1; vc drives
	// the colour ramp and the band reach, which saturate.
	float glow = v * band * strength;
	vec3 col = mix(color_lo, color_hi, vc);

	// blend_add ignores alpha for the add, so brightness must live in rgb.
	COLOR = vec4(col * glow, 1.0);
}
