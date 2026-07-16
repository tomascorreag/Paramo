extends GutTest

# Guards BurningCellVFX behaviour that isn't pure math. Today: the douse fade —
# when a fire is extinguished (rain / player) it must ease its intensity to 0
# rather than vanish on a frame. The full node needs a TileMapLayer to run
# _ready(), so these tests are white-box: they inject the minimum state and drive
# _process() by hand exactly as the engine would.

const VFX_SCRIPT: String = "res://scripts/vfx/burning_cell_vfx.gd"
const COLUMN_SCRIPT: String = "res://scripts/vfx/fire_blob_column.gd"


func test_douse_fades_intensity_smoothly_from_the_live_value() -> void:
	var vfx: BurningCellVFX = load(VFX_SCRIPT).new()
	# White-box setup: skip setup()/_ready (needs a live TileMapLayer). Inject a
	# couple of real blob columns and a starting intensity, then drive the fade by
	# hand. FireBlobColumn.new() configures fully in _init, so these are valid.
	var c1: FireBlobColumn = load(COLUMN_SCRIPT).new()
	var c2: FireBlobColumn = load(COLUMN_SCRIPT).new()
	vfx._columns.append(c1)
	vfx._columns.append(c2)
	vfx._intensity = 0.8

	vfx.begin_douse()
	assert_true(vfx._dousing, "begin_douse must enter the fade state")
	assert_almost_eq(vfx.get_intensity(), 0.8, 0.001,
		"the fade must start from the live intensity — no jump")

	# Advance ~75% of the fade (never reaching the free step, whose queue_free
	# timing is tree-dependent). Intensity must fall monotonically toward 0.
	var prev: float = vfx.get_intensity()
	var elapsed: float = 0.0
	while elapsed < BurningCellVFX.DOUSE_SECONDS * 0.75:
		vfx._process(0.05)
		elapsed += 0.05
		var now: float = vfx.get_intensity()
		assert_lte(now, prev + 0.0001, "douse intensity must never rise")
		prev = now

	assert_lt(prev, 0.4, "by 75% of the fade the flame has clearly shrunk toward 0")
	# The columns must have received the fading value, not the original 0.8.
	assert_almost_eq(c1._intensity, vfx.get_intensity(), 0.02,
		"the fade must be pushed down to the blob columns, not just tracked internally")

	c1.free()
	c2.free()
	vfx.free()


func test_douse_is_ignored_once_smouldering() -> void:
	# A burnout already owns the smooth tail; a late douse must not hijack it.
	var vfx: BurningCellVFX = load(VFX_SCRIPT).new()
	vfx._columns.append(load(COLUMN_SCRIPT).new())
	vfx._smouldering = true
	vfx.begin_douse()
	assert_false(vfx._dousing, "douse must no-op while smouldering")
	for col: FireBlobColumn in vfx._columns:
		col.free()
	vfx.free()
