class_name TerrainGenerator
extends Node2D

const TILE_SIZE := 16
const MAP_WIDTH := 60
const MAP_HEIGHT := 40

var dirt_tex := preload("res://assets/sprites/Tiles/dirt.png")
var shrubs2_tex := preload("res://assets/sprites/Tiles/shrubs2.png")
var shrubs1_tex := preload("res://assets/sprites/Tiles/shrubs1.png")
var ice1_tex := preload("res://assets/sprites/Tiles/ice1.png")
var ice2_tex := preload("res://assets/sprites/Tiles/ice2.png")
var ice3_tex := preload("res://assets/sprites/Tiles/ice3.png")

var altitude_noise: FastNoiseLite
var boundary_noise: FastNoiseLite


func _ready() -> void:
	altitude_noise = FastNoiseLite.new()
	altitude_noise.seed = randi()
	altitude_noise.frequency = 0.06
	altitude_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH

	boundary_noise = FastNoiseLite.new()
	boundary_noise.seed = randi()
	boundary_noise.frequency = 0.15
	boundary_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH

	queue_redraw()


func _get_altitude(x: int, y: int) -> float:
	# Gradient: top of map = high altitude (ice), bottom = low (shrubs)
	var gradient := 1.0 - (float(y) / float(MAP_HEIGHT))
	# Noise normalized to [0, 1]
	var n := altitude_noise.get_noise_2d(float(x), float(y)) * 0.5 + 0.5
	# Mostly gradient, noise breaks up the bands
	return gradient * 0.65 + n * 0.35


func _get_overlay(x: int, y: int, altitude: float) -> Texture2D:
	# Secondary noise perturbs thresholds for organic edges
	var edge := boundary_noise.get_noise_2d(float(x), float(y)) * 0.06
	var a := altitude + edge

	if a < 0.22:
		return shrubs2_tex
	elif a < 0.38:
		return shrubs1_tex
	elif a < 0.55:
		return null
	elif a < 0.68:
		return ice1_tex
	elif a < 0.82:
		return ice2_tex
	else:
		return ice3_tex


func _draw() -> void:
	for y in range(MAP_HEIGHT):
		for x in range(MAP_WIDTH):
			var pos := Vector2(x * TILE_SIZE, y * TILE_SIZE)
			draw_texture(dirt_tex, pos)
			var altitude := _get_altitude(x, y)
			var overlay := _get_overlay(x, y, altitude)
			if overlay:
				draw_texture(overlay, pos)
