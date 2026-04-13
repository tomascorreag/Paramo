class_name Frailejon
extends Node2D

const MAX_GROWTH_STAGE: int = 3

## Chance to grow each in-game hour. 1.0 = always, 0.5 = 50%.
@export var growth_chance: float = 0.6

@onready var _sprite: Sprite2D = $Sprite2D

var cell: Vector2i
var growth_stage: int = 0

var _time_manager: Node
var _last_hour: int = -1


func _ready() -> void:
	_sprite.flip_h = randf() < 0.5
	_sprite.position = Vector2(randf_range(-2.0, 2.0), randf_range(-1.0, 1.0))

	_time_manager = get_node_or_null("/root/TimeManager")
	if _time_manager:
		_last_hour = int(_time_manager.time_of_day * 24.0) % 24


func _process(_delta: float) -> void:
	if growth_stage >= MAX_GROWTH_STAGE or _time_manager == null:
		return
	var hour: int = int(_time_manager.time_of_day * 24.0) % 24
	if hour != _last_hour:
		_last_hour = hour
		if randf() <= growth_chance:
			set_growth_stage(growth_stage + 1)


func set_growth_stage(stage: int) -> void:
	growth_stage = clampi(stage, 0, MAX_GROWTH_STAGE)
	if _sprite:
		_sprite.frame = growth_stage
