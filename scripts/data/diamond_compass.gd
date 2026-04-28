class_name DiamondCompass
extends RefCounted

# ============================================================================
# DiamondCompass
# ============================================================================
#
# Single source of truth for the iso diamond's compass directions, neighbor
# bitmasks, and direction → bit lookup. Replaces what used to be three
# parallel copies (TerrainGenerator, TerrainCell, hardcoded face-bit values
# in TerrainPainter).
#
# The grid is a Diamond Down iso layout: cell (x, y)'s face neighbors are at
# (x, y-1)=NE, (x-1, y)=NW, (x+1, y)=SE, (x, y+1)=SW. The four diamond
# corners (visually straight up/right/down/left on screen) are the apex
# diagonals (-1,-1)=N, (1,-1)=E, (1,1)=S, (-1,1)=W.
#
# Bit layout for shore masks (4-bit face nibble + 4-bit apex nibble):
#   bit 0 (1)   = NE face neighbor
#   bit 1 (2)   = NW face neighbor
#   bit 2 (4)   = SE face neighbor
#   bit 3 (8)   = SW face neighbor
#   bit 4 (16)  = N apex neighbor
#   bit 5 (32)  = E apex neighbor
#   bit 6 (64)  = S apex neighbor
#   bit 7 (128) = W apex neighbor
#
# ============================================================================


# --- Face directions --------------------------------------------------------
const DIR_NE: Vector2i = Vector2i( 0, -1)
const DIR_NW: Vector2i = Vector2i(-1,  0)
const DIR_SE: Vector2i = Vector2i( 1,  0)
const DIR_SW: Vector2i = Vector2i( 0,  1)

# Iteration order matches FACE_BITS / FACE_DIRS pairings below.
const FACE_DIRS: Array[Vector2i] = [DIR_NE, DIR_NW, DIR_SE, DIR_SW]


# --- Apex (diamond-corner) directions ---------------------------------------
const DIR_APEX_N: Vector2i = Vector2i(-1, -1)
const DIR_APEX_E: Vector2i = Vector2i( 1, -1)
const DIR_APEX_S: Vector2i = Vector2i( 1,  1)
const DIR_APEX_W: Vector2i = Vector2i(-1,  1)

const APEX_DIRS: Array[Vector2i] = [DIR_APEX_N, DIR_APEX_E, DIR_APEX_S, DIR_APEX_W]


# --- Shore mask bits --------------------------------------------------------
const BIT_NE: int = 1
const BIT_NW: int = 2
const BIT_SE: int = 4
const BIT_SW: int = 8
const BIT_APEX_N: int = 16
const BIT_APEX_E: int = 32
const BIT_APEX_S: int = 64
const BIT_APEX_W: int = 128

const FACE_MASK: int = BIT_NE | BIT_NW | BIT_SE | BIT_SW
const APEX_MASK: int = BIT_APEX_N | BIT_APEX_E | BIT_APEX_S | BIT_APEX_W

# Aligned with FACE_DIRS / APEX_DIRS so iteration `for i in DIRS.size()` works.
const FACE_BITS: Array[int] = [BIT_NE, BIT_NW, BIT_SE, BIT_SW]
const APEX_BITS: Array[int] = [BIT_APEX_N, BIT_APEX_E, BIT_APEX_S, BIT_APEX_W]


# Returns the face-bit value for `dir`, or 0 if `dir` isn't one of the four
# face directions. Inline branches because Vector2i isn't hashable as a dict
# key in 4.6 (would force a string-keyed dict; explicit `if`s are clearer).
static func face_bit_for_dir(dir: Vector2i) -> int:
	if dir == DIR_NE: return BIT_NE
	if dir == DIR_NW: return BIT_NW
	if dir == DIR_SE: return BIT_SE
	if dir == DIR_SW: return BIT_SW
	return 0


# Returns the apex-bit value for `dir`, or 0 if `dir` isn't an apex.
static func apex_bit_for_dir(dir: Vector2i) -> int:
	if dir == DIR_APEX_N: return BIT_APEX_N
	if dir == DIR_APEX_E: return BIT_APEX_E
	if dir == DIR_APEX_S: return BIT_APEX_S
	if dir == DIR_APEX_W: return BIT_APEX_W
	return 0
