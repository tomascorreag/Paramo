@tool
class_name ViewportPanel
extends Control

## Draws its SubViewport children at their own size, top-left aligned: the part of
## SubViewportContainer the journal uses, without the class itself.
##
## SubViewportContainer is compiled out of the web build (it sits behind
## disable_advanced_gui, worth ~0.5 MB of the download; see dev-notes/web-engine.md).
## This mirrors its 4.6 behaviour for stretch = false: draw each child's texture
## at Rect2(0, size), render the child only while this node is visible in the tree,
## and report the child's size as the minimum size. Input forwarding is NOT
## reproduced. The journal never used it: its pages are mouse_filter = IGNORE with
## gui_disable_input viewports, and JournalShopInput maps clicks itself.


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_ENTER_TREE, NOTIFICATION_VISIBILITY_CHANGED:
			var mode := SubViewport.UPDATE_ALWAYS if is_visible_in_tree() else SubViewport.UPDATE_DISABLED
			for sub in _sub_viewports():
				sub.render_target_update_mode = mode
				sub.handle_input_locally = false
		NOTIFICATION_DRAW:
			for sub in _sub_viewports():
				draw_texture_rect(sub.get_texture(), Rect2(Vector2.ZERO, Vector2(sub.size)), false)


func _get_minimum_size() -> Vector2:
	var out := Vector2.ZERO
	for sub in _sub_viewports():
		out = out.max(Vector2(sub.size))
	return out


func _sub_viewports() -> Array[SubViewport]:
	var out: Array[SubViewport] = []
	for child in get_children():
		if child is SubViewport:
			out.append(child as SubViewport)
	return out
