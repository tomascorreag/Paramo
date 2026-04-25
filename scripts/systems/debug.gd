extends Node
## Autoload registered as "Debug" in project.godot.
## Cannot use class_name — Godot disallows class_name matching an autoload name.
##
## Global debug switch. When `enabled` is true, debug UIs (e.g. DebugOverlay)
## become visible and respond to input. Toggled at runtime via the
## `ui_toggle_debug` input action (F3), but only inside debug builds —
## release exports never flip the flag.

signal enabled_changed(is_enabled: bool)

var enabled: bool = false:
	set(value):
		if value == enabled:
			return
		enabled = value
		enabled_changed.emit(enabled)


func _unhandled_input(event: InputEvent) -> void:
	if not OS.is_debug_build():
		return
	if event.is_action_pressed(&"ui_toggle_debug"):
		enabled = not enabled
		get_viewport().set_input_as_handled()
