extends Node2D

const TILE_SIZE := 16
const COLOR_A := Color(0.15, 0.15, 0.15)
const COLOR_B := Color(0.2, 0.2, 0.2)
const GRID_SIZE := 60


func _draw() -> void:
	for x in range(-GRID_SIZE, GRID_SIZE):
		for y in range(-GRID_SIZE, GRID_SIZE):
			var color := COLOR_A if (x + y) % 2 == 0 else COLOR_B
			draw_rect(Rect2(x * TILE_SIZE, y * TILE_SIZE, TILE_SIZE, TILE_SIZE), color)
