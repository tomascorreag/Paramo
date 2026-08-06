extends GutTest

# Pins the shared movement/douse statics extracted for the balance simulator:
# TileGrid.step_duration_for must reproduce the player's old inline duration
# table exactly (the bot's travel times ARE the player's travel times), and
# ActionExtinguishFire.footprint_by_ring must keep the ring-outward douse
# order the action has always used.

const BASE: float = 0.45
const CLIMB: float = 2.0
const SCRAMBLE: float = 4.0


func _dur(kind: int, alt_delta: float) -> float:
	return TileGrid.step_duration_for(kind, alt_delta, BASE, CLIMB, SCRAMBLE)


func test_flat_and_ramp_axis_take_one_base_step() -> void:
	assert_almost_eq(_dur(TileGrid.StepKind.FLAT, 0.0), BASE, 0.0001)
	assert_almost_eq(_dur(TileGrid.StepKind.RAMP_AXIS, 1.0), BASE, 0.0001,
			"ramp-axis walking is priced as a normal step")


func test_ladder_scales_with_cubes_and_clamps_to_one() -> void:
	assert_almost_eq(_dur(TileGrid.StepKind.LADDER, 2.0), BASE * CLIMB * 1.0, 0.0001)
	assert_almost_eq(_dur(TileGrid.StepKind.LADDER, 6.0), BASE * CLIMB * 3.0, 0.0001)
	assert_almost_eq(_dur(TileGrid.StepKind.LADDER, 0.0), BASE * CLIMB * 1.0, 0.0001,
			"degenerate 0-delta edge still costs one climb step")


func test_scramble_scales_with_height_unclamped() -> void:
	assert_almost_eq(_dur(TileGrid.StepKind.SCRAMBLE, 1.0), BASE * SCRAMBLE * 0.5,
			0.0001, "half-step ledge -> 2x a base step")
	assert_almost_eq(_dur(TileGrid.StepKind.SCRAMBLE, 2.0), BASE * SCRAMBLE * 1.0,
			0.0001, "full cube -> 4x, double the ladder price")


func test_ramp_side_is_flat_double() -> void:
	assert_almost_eq(_dur(TileGrid.StepKind.RAMP_SIDE, 0.5), BASE * CLIMB, 0.0001)


func test_footprint_by_ring_orders_center_first() -> void:
	var c := Vector2i(10, 10)
	var cells: Array[Vector2i] = ActionExtinguishFire.footprint_by_ring(c, 1)
	assert_eq(cells.size(), 9)
	assert_eq(cells[0], c, "ring 0 is the clicked cell itself")
	# Ring 1 keeps the row-major scan order the action always used.
	assert_eq(cells[1], c + Vector2i(-1, -1))
	assert_eq(cells[8], c + Vector2i(1, 1))
	for i in range(1, 9):
		var d: Vector2i = cells[i] - c
		assert_eq(maxi(absi(d.x), absi(d.y)), 1, "cells 1..8 are all ring 1")
