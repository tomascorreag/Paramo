# Shader Code Review — 2026-04-16

## Files Reviewed
- `assets/shaders/player_shadow.gdshader`
- `assets/shaders/post_process.gdshader`
- `assets/shaders/shadow_oval.gdshader`
- `assets/shaders/water.gdshader`
- `assets/shaders/wind.gdshader`

## Summary
- Critical: 0
- High: 5
- Medium: 7
- Low: 5
- Total: 17

No correctness-critical bugs. Main wins are in `water.gdshader` and `wind.gdshader` (high-instance-count tilemap shaders): several per-fragment computations are actually per-draw-call constants that should be precomputed on the CPU or moved to the vertex shader.

---

## High Priority

### [H1] water: per-fragment `length`/`normalize`/`cos`/`sin` on uniform-only inputs
- **File:** `assets/shaders/water.gdshader:59-63`
- **Issue:** `flow_direction` is a uniform, so `length(flow_direction)` (sqrt) and `normalize(flow_direction)` (sqrt+mul) are evaluated identically on every fragment of every water tile, every frame. With hundreds of tiles this is pure waste. Trig in the still-water branch is cheap per se but the whole branch is avoidable.
- **Fix:** Replace `flow_direction` + `flow_speed` with a single CPU-precomputed `uniform vec2 scroll_velocity`. Fragment becomes `vec2 scroll = scroll_velocity * TIME;`. Visual result identical.

### [H2] wind: per-fragment `normalize` on a constant uniform
- **File:** `assets/shaders/wind.gdshader:46`
- **Issue:** `normalize(wind_strength + vec2(0.0001)) * wind_speed * TIME` resolves to `<constant direction> * TIME`. Evaluated per-fragment on every wind tile.
- **Fix:** Expose a `uniform vec2 wind_scroll_per_second` precomputed in GDScript as `normalize(wind_strength) * wind_speed`. Fragment: `vec2 scroll = wind_scroll_per_second * TIME;`.

### [H3] water: redundant `combined * water_intensity` multiplications
- **File:** `assets/shaders/water.gdshader:71-78`
- **Issue:** `combined * intensity` computed three times; `flow_off` also multiplies a vec2 by scalars that were already computed.
- **Fix:**
```glsl
float ci = combined * water_intensity;
float v_offset = round(ci * vertical_strength) * TEXTURE_PIXEL_SIZE.y;
vec2  flow_off = round(flow_direction * (ci * ripple_strength)) * TEXTURE_PIXEL_SIZE;
vec4  tex      = texture(TEXTURE, UV + flow_off + vec2(0.0, v_offset));
float wave     = ci * highlight_strength;
```

### [H4] wind: dead code — `tile_x` computed, never used
- **File:** `assets/shaders/wind.gdshader:54`
- **Fix:** Delete the `tile_x` line.

### [H5] shadow_oval: fragment recomputes what vertex already derived
- **File:** `assets/shaders/shadow_oval.gdshader:31-37`
- **Issue:** `abs_len`, `extent`, `dir`, and the pixel coords are fully recomputed in the fragment stage from the same uniforms the vertex already used. Single-entity shader so impact is low, but this is the wrong architecture pattern.
- **Fix:** Emit `px`, `py` (or `fpx`, `py`) as varyings from vertex.

---

## Medium Priority

### [M1] water/wind: debug uniform branches live in release shader
- **Files:** `assets/shaders/water.gdshader:26,91-95`, `assets/shaders/wind.gdshader:17,62-73`
- **Issue:** `debug == 1` / `wind_debug == 1` branches run every fragment even at default 0. Bloats the compiled shader and obstructs compiler optimizations.
- **Fix:** Wrap in a `const bool DEBUG_ENABLED = false;` guard (compile-time dead-strip), or use Godot 4.x `#ifdef WATER_DEBUG` preprocessor.

### [M2] water+wind: `_hash`/`_noise` duplicated byte-for-byte
- **Files:** `assets/shaders/water.gdshader:30-47`, `assets/shaders/wind.gdshader:21-38`
- **Fix:** Godot 4.1+ supports `#include "res://..."` for `.gdshaderinc`. Factor into `assets/shaders/noise_common.gdshaderinc` and include from both.

### [M3] post_process: `length()` on full-screen vignette → use squared distance
- **File:** `assets/shaders/post_process.gdshader:39-40`
- **Issue:** sqrt per pixel at full resolution. `smoothstep` only needs comparison, not true distance.
- **Fix:** `float dist_sq = dot(uv_centered, uv_centered);` and square both smoothstep thresholds (pre-square on CPU if exact falloff semantics matter).

### [M4] shadow_oval: `pow()` in fragment (flagged, low impact)
- **File:** `assets/shaders/shadow_oval.gdshader:53`
- **Issue:** `pow(x, uniform)` is `exp(c * log(x))`. Single-entity shader so cost is negligible — noted for completeness only.

### [M5] water: `round(world_pos + 0.5)` should be in vertex shader
- **File:** `assets/shaders/water.gdshader:55`
- **Fix:** Round in vertex, pass as varying. Removes per-fragment round+add on every water tile.
```glsl
// vertex():
world_pos = round((MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy + vec2(0.5, 0.5));
// fragment(): use world_pos directly
```

### [M6] post_process: `tint_color` should be `vec3`, not `vec4`
- **File:** `assets/shaders/post_process.gdshader:14,35`
- **Issue:** Only `.rgb` is read — alpha component wastes a register slot. `source_color` hint works on `vec3`.

### [M7] wind: `snapped_mask` derivation runs per-fragment on uniform inputs
- **File:** `assets/shaders/wind.gdshader:56-57`
- **Issue:** `floor(wind_mask * 32.0) / 32.0` is computed every fragment even though `wind_mask` is a uniform.
- **Fix:** Compute on CPU, expose as `uniform float wind_snapped_mask`.

---

## Low Priority

### [L1] player_shadow: hardcoded `* 0.5` alpha is invisible to artists
- **File:** `assets/shaders/player_shadow.gdshader:18`
- **Fix:** Fold into `shadow_color.a` semantics, or add a `shadow_opacity` uniform matching `shadow_oval.gdshader`.

### [L2] shadow_oval: double-alpha (`shadow_color.a * shadow_opacity`) confuses artists
- **File:** `assets/shaders/shadow_oval.gdshader:7,13,58`
- **Fix:** Pick one: keep only `shadow_color.a`, or make `shadow_color` a `vec3` and use `shadow_opacity`.

### [L3] wind: `uv_offset` and `inv_tile_size_uv` are per-draw-call constants
- **File:** `assets/shaders/wind.gdshader:52-54`
- **Issue:** `TEXTURE_PIXEL_SIZE * wind_tile_offset` and `wind_tile_size * TEXTURE_PIXEL_SIZE` are identical every fragment.
- **Fix:** Pre-multiply on CPU and expose as uniforms, or move to vertex as varyings.

### [L4] post_process: vignette falloff width hardcoded at `0.5`
- **File:** `assets/shaders/post_process.gdshader:40`
- **Fix:** Add `uniform float vignette_softness : hint_range(0.01, 1.0) = 0.5`.

### [L5] water: `debug` hint promises 0..3 but only mode 1 implemented
- **File:** `assets/shaders/water.gdshader:26,91-95`
- **Fix:** Either implement modes 2/3 (to match wind.gdshader) or narrow hint to `hint_range(0, 1)`.

---

## What's Done Well
- `player_shadow.gdshader` — minimal fragment work; shadow projection correctly done in vertex.
- `shadow_oval.gdshader` — appropriate use of `discard` for non-rectangular shape.
- `post_process.gdshader` — standard color-grading op order; correct BT.601 luminance weights.
- `water`/`wind` — `world_pos` varying pattern is the correct way to anchor animated noise across Godot's atlas-relative UVs. `round()` on UV offsets is correct pixel-art discipline.
