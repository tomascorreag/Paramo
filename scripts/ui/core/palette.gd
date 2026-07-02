class_name Palette
extends RefCounted

## Single source of truth for the project palette (assets/palettes/palette2.txt).
##
## All UI / HUD / shader / gizmo RGB in code and .tres MUST come from here — see
## CLAUDE.md "Color Palette". RGB is locked to these 33 entries; alpha is the
## only free knob (apply it with `with_alpha`). Index 32 duplicates index 00.
##
## Two access styles:
##   Palette.ACCENT          — semantic alias (preferred at call sites)
##   Palette.P17 / at(17)    — raw indexed entry (when no alias fits)
##
## Colors are authored as Color(0xRR/255.0, ...) so they are const-evaluable and
## byte-exact to the source hex.

# --- Indexed entries (P00..P32) ---
const P00 := Color(0x63 / 255.0, 0x66 / 255.0, 0x63 / 255.0)
const P01 := Color(0x87 / 255.0, 0x85 / 255.0, 0x7C / 255.0)
const P02 := Color(0xBC / 255.0, 0xAD / 255.0, 0x9F / 255.0)
const P03 := Color(0xF2 / 255.0, 0xB8 / 255.0, 0x88 / 255.0)
const P04 := Color(0xEB / 255.0, 0x96 / 255.0, 0x61 / 255.0)
const P05 := Color(0xB5 / 255.0, 0x59 / 255.0, 0x45 / 255.0)
const P06 := Color(0x73 / 255.0, 0x4C / 255.0, 0x44 / 255.0)
const P07 := Color(0x3D / 255.0, 0x33 / 255.0, 0x33 / 255.0)
const P08 := Color(0x59 / 255.0, 0x3E / 255.0, 0x47 / 255.0)
const P09 := Color(0x7A / 255.0, 0x58 / 255.0, 0x59 / 255.0)
const P10 := Color(0xA5 / 255.0, 0x78 / 255.0, 0x55 / 255.0)
const P11 := Color(0xDE / 255.0, 0x9F / 255.0, 0x47 / 255.0)
const P12 := Color(0xFD / 255.0, 0xD1 / 255.0, 0x79 / 255.0)
const P13 := Color(0xFE / 255.0, 0xE1 / 255.0, 0xB8 / 255.0)
const P14 := Color(0xD4 / 255.0, 0xC6 / 255.0, 0x92 / 255.0)
const P15 := Color(0xA6 / 255.0, 0xB0 / 255.0, 0x4F / 255.0)
const P16 := Color(0x81 / 255.0, 0x94 / 255.0, 0x47 / 255.0)
const P17 := Color(0x44 / 255.0, 0x70 / 255.0, 0x2D / 255.0)
const P18 := Color(0x2F / 255.0, 0x4D / 255.0, 0x2F / 255.0)
const P19 := Color(0x54 / 255.0, 0x67 / 255.0, 0x56 / 255.0)
const P20 := Color(0x89 / 255.0, 0xA4 / 255.0, 0x77 / 255.0)
const P21 := Color(0xA4 / 255.0, 0xC5 / 255.0, 0xAF / 255.0)
const P22 := Color(0xCA / 255.0, 0xE6 / 255.0, 0xD9 / 255.0)
const P23 := Color(0xF1 / 255.0, 0xF6 / 255.0, 0xF0 / 255.0)
const P24 := Color(0xD5 / 255.0, 0xD6 / 255.0, 0xDB / 255.0)
const P25 := Color(0xBB / 255.0, 0xC3 / 255.0, 0xD0 / 255.0)
const P26 := Color(0x96 / 255.0, 0xA9 / 255.0, 0xC1 / 255.0)
const P27 := Color(0x6C / 255.0, 0x81 / 255.0, 0xA1 / 255.0)
const P28 := Color(0x40 / 255.0, 0x52 / 255.0, 0x73 / 255.0)
const P29 := Color(0x30 / 255.0, 0x38 / 255.0, 0x43 / 255.0)
const P30 := Color(0x14 / 255.0, 0x23 / 255.0, 0x3A / 255.0)
const P31 := Color(0x41 / 255.0, 0x44 / 255.0, 0x46 / 255.0)
const P32 := P00

const COLORS: Array[Color] = [
	P00, P01, P02, P03, P04, P05, P06, P07, P08, P09,
	P10, P11, P12, P13, P14, P15, P16, P17, P18, P19,
	P20, P21, P22, P23, P24, P25, P26, P27, P28, P29,
	P30, P31, P32,
]

# --- Semantic UI aliases (role -> index) ---
const ACCENT := P12       ## FDD179 gold highlight (hover/pressed border, markers)
const ACCENT_SOFT := P11  ## DE9F47 dimmer gold
const PANEL_BG := P30     ## 14233A darkest — panel/menu fill, slit, overlay dim
const SURFACE := P29      ## 303843 inner fills / pressed bg
const HOVER := P28        ## 405273 hover bg / border-dim / progress track
const BORDER := P27       ## 6C81A1 frame borders
const PROGRESS := P20     ## 89A477 progress-bar fill
const TEXT := P23         ## F1F6F0 primary label text
const TEXT_DIM := P01     ## 87857C secondary/status text
const DANGER := P05       ## B55945 denied/invalid flash
const SHADOW := P30       ## 14233A text/UI drop shadow


## Indexed access with clamping (0..32).
static func at(index: int) -> Color:
	return COLORS[clampi(index, 0, COLORS.size() - 1)]


## Copy of `c` with alpha `a` — RGB stays locked, alpha is the free knob.
static func with_alpha(c: Color, a: float) -> Color:
	return Color(c.r, c.g, c.b, a)
