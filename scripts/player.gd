class_name Player
extends CharacterBody2D

@export var speed: float = 80.0


func _physics_process(_delta: float) -> void:
	var input_dir := Vector2(
		Input.get_axis("move_left", "move_right"),
		Input.get_axis("move_up", "move_down")
	)

	if input_dir.length() > 1.0:
		input_dir = input_dir.normalized()

	velocity = input_dir * speed
	move_and_slide()
