extends GutTest

# Guards the stretch-mode toggle on the real DisplayManager autoload (it owns the
# root Window, so a fresh instance would fight the singleton over content_scale_*).
#
# Scope: the WIRING (config -> window, toggle round-trip, signal, scale maths).
# The engine's actual behaviour under each mode was verified empirically, not
# here — a headless GUT run has no rendering context, so the framebuffer size
# that actually distinguishes the modes cannot be read. Measured on an RTX 3080
# at a 1440x810 window, content_scale_size (360, 202):
#   CANVAS_ITEMS -> framebuffer 1440x810  (rasterize at window res)
#   VIEWPORT     -> framebuffer  360x203  (rasterize low-res, upscale by N)
# i.e. VIEWPORT is an N**2 = 16x fill reduction, and the toggle survives being
# flipped back and forth at runtime.

var _restore_mode: Window.ContentScaleMode


func before_each() -> void:
	_restore_mode = DisplayManager.get_stretch_mode()


func after_each() -> void:
	DisplayManager.set_stretch_mode(_restore_mode)


func test_config_stretch_mode_is_applied_to_window() -> void:
	# _ready copies config.stretch_mode onto the Window; nothing else should.
	assert_eq(
		DisplayManager.get_stretch_mode(),
		DisplayManager.config.stretch_mode as Window.ContentScaleMode,
		"window content_scale_mode should mirror display_config.tres"
	)


func test_content_scale_factor_is_pinned_to_one() -> void:
	# Live in BOTH modes (window.cpp divides by it in each branch), so a stray
	# value would fight the window/N maths whichever mode is selected.
	assert_eq(DisplayManager.get_window().content_scale_factor, 1.0)


func test_set_stretch_mode_switches_and_emits() -> void:
	DisplayManager.set_stretch_mode(Window.CONTENT_SCALE_MODE_CANVAS_ITEMS)
	watch_signals(DisplayManager)

	DisplayManager.set_stretch_mode(Window.CONTENT_SCALE_MODE_VIEWPORT)

	assert_eq(DisplayManager.get_stretch_mode(), Window.CONTENT_SCALE_MODE_VIEWPORT)
	assert_signal_emitted_with_parameters(
		DisplayManager, "stretch_mode_changed", [Window.CONTENT_SCALE_MODE_VIEWPORT]
	)


func test_set_stretch_mode_is_idempotent() -> void:
	DisplayManager.set_stretch_mode(Window.CONTENT_SCALE_MODE_VIEWPORT)
	watch_signals(DisplayManager)

	DisplayManager.set_stretch_mode(Window.CONTENT_SCALE_MODE_VIEWPORT)

	assert_signal_not_emitted(
		DisplayManager, "stretch_mode_changed", "re-setting the live mode should be a no-op"
	)


func test_toggle_round_trips() -> void:
	DisplayManager.set_stretch_mode(Window.CONTENT_SCALE_MODE_CANVAS_ITEMS)

	DisplayManager.toggle_stretch_mode()
	assert_eq(DisplayManager.get_stretch_mode(), Window.CONTENT_SCALE_MODE_VIEWPORT)

	DisplayManager.toggle_stretch_mode()
	assert_eq(DisplayManager.get_stretch_mode(), Window.CONTENT_SCALE_MODE_CANVAS_ITEMS)


func test_toggle_writes_back_to_config() -> void:
	# The debug toggle is meant to be sticky within a session: DisplayManager
	# re-reads config.stretch_mode on nothing else, but set_base_resolution and
	# resizes must not silently revert the user's choice.
	DisplayManager.set_stretch_mode(Window.CONTENT_SCALE_MODE_VIEWPORT)
	assert_eq(DisplayManager.config.stretch_mode, Window.CONTENT_SCALE_MODE_VIEWPORT)


func test_stretch_mode_does_not_disturb_the_scale_maths() -> void:
	# The framing must be identical across modes — content_scale_size is
	# window/N either way, so only rasterization resolution changes.
	DisplayManager.set_stretch_mode(Window.CONTENT_SCALE_MODE_CANVAS_ITEMS)
	var canvas_vp: Vector2i = DisplayManager.effective_viewport_size
	var canvas_scale: int = DisplayManager.current_scale

	DisplayManager.set_stretch_mode(Window.CONTENT_SCALE_MODE_VIEWPORT)

	assert_eq(DisplayManager.effective_viewport_size, canvas_vp, "viewport size must not move")
	assert_eq(DisplayManager.current_scale, canvas_scale, "integer scale must not move")


func test_stretch_stays_fractional() -> void:
	# CONTENT_SCALE_STRETCH_INTEGER looks like the "more correct" choice for a
	# pixel grid and is a measured trap under CONTENT_SCALE_ASPECT_EXPAND: EXPAND
	# grows the viewport past content_scale_size, so window/viewport falls below N
	# and INTEGER floors a 4x upscale to 3x with a large letterbox. See the note
	# in DisplayManager._ready.
	DisplayManager.set_stretch_mode(Window.CONTENT_SCALE_MODE_VIEWPORT)
	assert_eq(
		DisplayManager.get_window().content_scale_stretch,
		Window.CONTENT_SCALE_STRETCH_FRACTIONAL
	)
