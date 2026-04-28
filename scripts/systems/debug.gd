extends Node
## Autoload registered as "Debug" in project.godot.
## Cannot use class_name — Godot disallows class_name matching an autoload name.
##
## Global debug switch. When `enabled` is true, debug UIs (e.g. DebugOverlay)
## become visible and respond to input. Toggled at runtime via the
## `ui_toggle_debug` input action (F3), but only inside debug builds —
## release exports never flip the flag.

signal enabled_changed(is_enabled: bool)
signal tile_indices_changed(is_enabled: bool)
signal tile_altitudes_changed(is_enabled: bool)
signal free_movement_changed(is_enabled: bool)

var enabled: bool = false:
	set(value):
		if value == enabled:
			return
		enabled = value
		enabled_changed.emit(enabled)

## When true, debug overlays should draw each tile's grid coord at its center.
var show_tile_indices: bool = false:
	set(value):
		if value == show_tile_indices:
			return
		show_tile_indices = value
		tile_indices_changed.emit(show_tile_indices)

## When true, debug overlays should draw each cell's highest-visible-top
## altitude (the value Pathfinder.highest_visible_top returns — what the
## shadow cutoff compares against). Independent of show_tile_indices.
var show_tile_altitudes: bool = false:
	set(value):
		if value == show_tile_altitudes:
			return
		show_tile_altitudes = value
		tile_altitudes_changed.emit(show_tile_altitudes)

## When true, a debug-only Camera2D takes over from the player camera and
## pans on WASD. Click-to-move stays active but the camera no longer follows
## the player. Toggled via the Free Move row in the debug overlay.
var free_movement: bool = false:
	set(value):
		if value == free_movement:
			return
		free_movement = value
		free_movement_changed.emit(free_movement)


func _unhandled_input(event: InputEvent) -> void:
	if not OS.is_debug_build():
		return
	if event.is_action_pressed(&"ui_toggle_debug"):
		enabled = not enabled
		get_viewport().set_input_as_handled()
