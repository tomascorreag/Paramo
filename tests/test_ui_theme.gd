extends GutTest

# Guards the authored UI theme + stylebox library (resources/ui). These resources
# render the UI styled in the editor and are the source of truth for static
# styling; the tests catch a dropped theme type item or a broken stylebox
# region/margin (which would silently unstyle controls).

const THEME: Theme = preload("res://resources/ui/paramo_theme.tres")


func test_theme_has_control_styleboxes() -> void:
	assert_true(THEME.has_stylebox("normal", "Button"), "Button/normal missing")
	assert_true(THEME.has_stylebox("hover", "Button"), "Button/hover missing")
	assert_true(THEME.has_stylebox("pressed", "Button"), "Button/pressed missing")
	assert_true(THEME.has_stylebox("panel", "Panel"), "Panel/panel missing")
	assert_true(THEME.has_stylebox("panel", "PanelContainer"), "PanelContainer/panel missing")
	assert_true(THEME.has_stylebox("slider", "HSlider"), "HSlider/slider missing")
	assert_true(THEME.has_stylebox("grabber_area", "HSlider"), "HSlider/grabber_area missing")
	assert_true(THEME.has_stylebox("background", "ProgressBar"), "ProgressBar/background missing")
	assert_true(THEME.has_stylebox("fill", "ProgressBar"), "ProgressBar/fill missing")


func test_theme_keeps_font() -> void:
	assert_not_null(THEME.default_font, "default_font dropped")
	assert_eq(THEME.default_font_size, 8)


func test_solid_stylebox_region_and_margins() -> void:
	var sb: StyleBoxTexture = preload("res://resources/ui/styleboxes/solid_surface.tres")
	assert_eq(sb.region_rect, Rect2(20, 20, 8, 8), "solid region must be col-2 fill sprite")
	assert_eq(sb.texture_margin_left, 2.0)
	assert_not_null(sb.texture, "stylebox lost its atlas texture")


func test_frame_stylebox_region_and_margins() -> void:
	var sb: StyleBoxTexture = preload("res://resources/ui/styleboxes/frame_border.tres")
	assert_eq(sb.region_rect, Rect2(3, 19, 10, 10), "frame region must be col-1 outline sprite")
	assert_eq(sb.texture_margin_left, 3.0)
	assert_not_null(sb.texture)
