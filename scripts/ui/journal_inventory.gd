@tool
class_name JournalInventory
extends Control

## The supplies list PRINTED on the journal's left page: one row per carried
## resource, its icon on the left and the amount beside it.
##
## It sits inside PageLeft's SubViewport, so page_warp.gdshader bends it along with
## the entry text above it — this is stock written into the book, not kit lying
## next to it. (Contrast PageSlit, which exists precisely for the one thing that
## must NOT bend: the season wheel behind the page.) Consequence: each row is one
## warp block tall (18 texels), and both the 16px icon and the Tiny5-16 count sit
## inside their row, so no ink touches a block seam.
##
## STUB: the amounts are authored numbers. There is no ResourceManager yet, so
## nothing feeds this; when there is one, connect its change signal to
## `set_amount` and delete the `@export` defaults. The row set is authored in
## scenes/ui/field_journal.tscn — this script only knows how to fill rows in.
##
## Expected children, one group per resource, named by its id:
##   <id> : Control
##     Icon  : TextureRect
##     Count : Label
##
## @tool so the authored stub amounts render in the editor.

## Amount shown for the `water` row. Stub until the resource system exists.
@export var water: int = 0:
	set(value):
		water = value
		_refresh(&"water", value)

## Amount shown for the `money` row. Stub until the resource system exists.
@export var money: int = 0:
	set(value):
		money = value
		_refresh(&"money", value)


func _ready() -> void:
	# Ink on paper takes no input, and the page's SubViewport has gui_disable_input
	# set anyway — IGNORE keeps this out of the picking pass entirely.
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_refresh(&"water", water)
	_refresh(&"money", money)


## Sets the number under one row's icon. Unknown ids are ignored rather than
## asserted: the row set is authored in the scene, so a missing row is a scene
## edit, not a caller bug.
func set_amount(id: StringName, value: int) -> void:
	match id:
		&"water":
			water = value
		&"money":
			money = value
		_:
			_refresh(id, value)


func _refresh(id: StringName, value: int) -> void:
	# Null-tolerant: the setters fire during scene load, before the rows exist.
	var label := get_node_or_null(NodePath("%s/Count" % id)) as Label
	if label != null:
		label.text = str(value)
