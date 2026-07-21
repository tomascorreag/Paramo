extends GutTest

# Season wheel rotation in the Field Journal. The wheel angle is driven continuously
# from the season clock in FieldJournal._process: a half-turn (180°) per season, where
# seasons_elapsed = (day_count + time_of_day) / days_per_season. (Gauge + logic moved
# out of the HUD into the journal; the rotation math is unchanged.)

const JOURNAL_SCENE: PackedScene = preload("res://scenes/ui/field_journal.tscn")

var journal: CanvasLayer
var _wheel: TextureRect


func before_each() -> void:
	# days_per_season is derived (days_per_year / seasons-per-year); pin it to 4
	# regardless of the cycle another test left behind.
	SeasonManager.days_per_year = 4 * maxi(1, SeasonManager.season_cycle.size())
	journal = JOURNAL_SCENE.instantiate()
	add_child_autofree(journal)
	_wheel = journal._season_wheel


func after_each() -> void:
	SeasonManager.phase = SeasonManager.Phase.IDLE
	TimeManager.paused = true


func test_idle_holds_at_zero() -> void:
	SeasonManager.phase = SeasonManager.Phase.IDLE
	TimeManager.day_count = 3  # nonzero clock must be ignored while idle
	TimeManager.time_of_day = 0.5
	journal._process(0.0)
	assert_eq(_wheel.rotation, 0.0)


func test_half_season_is_quarter_turn() -> void:
	SeasonManager.phase = SeasonManager.Phase.ACTIVE
	TimeManager.day_count = 2  # 2 of 4 days = half a season
	TimeManager.time_of_day = 0.0
	journal._process(0.0)
	assert_almost_eq(_wheel.rotation, deg_to_rad(90.0), 0.0001)


func test_full_season_is_half_turn() -> void:
	# One full season (4 days) lands rain-up at 180° — the wet season's top.
	SeasonManager.phase = SeasonManager.Phase.ACTIVE
	TimeManager.day_count = 4
	TimeManager.time_of_day = 0.0
	journal._process(0.0)
	assert_almost_eq(_wheel.rotation, deg_to_rad(180.0), 0.0001)


func test_rotation_advances_with_time_of_day() -> void:
	SeasonManager.phase = SeasonManager.Phase.ACTIVE
	TimeManager.day_count = 0
	TimeManager.time_of_day = 0.0
	journal._process(0.0)
	var start: float = _wheel.rotation
	TimeManager.time_of_day = 0.5  # half a day later, clock advanced
	journal._process(0.0)
	assert_gt(_wheel.rotation, start)


func test_two_seasons_is_full_turn() -> void:
	SeasonManager.phase = SeasonManager.Phase.ACTIVE
	TimeManager.day_count = 8  # two seasons
	TimeManager.time_of_day = 0.0
	journal._process(0.0)
	assert_almost_eq(_wheel.rotation, deg_to_rad(360.0), 0.0001)
