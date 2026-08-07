@tool
class_name JournalInkLayer
extends Control

## A bare Control whose only job is to CARRY a material for part of another node's
## drawing.
##
## A CanvasItem's material covers everything that item draws. On the journal that
## is a problem with no way around it: assets/shaders/journal_ink.gdshader recolours
## art through a gradient ramp, and a section that wants its icons inked but its
## text and rules in flat ink cannot put that shader on itself — the text would go
## through the ramp too. JournalKnownSet dodges it by making every swatch a child
## TextureRect (see the comment above its `_rebuild`).
##
## RunCalendar cannot use that dodge: its icons are three per lived day, up to 72 of
## them, repositioned on every day tick. Making them nodes would mean rebuilding 72
## TextureRects a day to draw 72 sprites. So instead the PARENT keeps its own
## drawing and hands the inked part to one of these, which draws it via `painter`
## with the material attached. One node, one material, no rebuild.
##
## Draws AFTER its parent by virtue of being a child, which is also the stacking the
## calendar wants: the day stamp is a backdrop and the icons sit on top of it.

## Called from _draw with this node as its only argument. Set by the parent, which
## keeps the geometry — this node deliberately knows nothing about what it paints.
var painter: Callable = Callable()


func _ready() -> void:
	# Ink on paper takes no input, and this sits directly over its parent's whole
	# rect, so leaving it pickable would shadow anything underneath.
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _draw() -> void:
	if painter.is_valid():
		painter.call(self)
