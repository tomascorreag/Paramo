# Paramo

A tower defense / environmental strategy game built in **Godot 4.6** with GDScript.

## Premise

You are a field coordinator protecting a Colombian **paramo** — a high-altitude Andean ecosystem that functions as a natural water factory. Threats climb the mountain from below: miners, tourists, cattle, invasive species. Environmental hazards strike from all directions: drought, fire, erosion, climate shift.

The paramo operates on geological time. Humans destroy on industrial time. Your job is not to win — it's to endure.

## Gameplay

- **10 seasons** of planning and real-time defense on a single handcrafted isometric mountain
- Plant frailejones, build trails, fences, channels, and monitoring stations
- Manage 3 resources: water, funding, and community support
- Physically traverse the mountain — altitude affects movement, growth, and exposure
- Protect the glacial laguna at the summit. If it dies, everything dies.

## Tech

- **Engine:** Godot 4.6.1 (Standard)
- **Language:** GDScript
- **Art:** Isometric pixel art (diamond tiles, 2:1 aspect)
- **Resolution:** 384x216 native, scaled 3x

## Running

```bash
# Run the game
"../Godot_v4.6.1-stable_win64_console.exe" --path .

# Open in editor
"../Godot_v4.6.1-stable_win64.exe" --path . --editor
```

## Project Structure

```
scenes/        # .tscn scene files (entities, tools, UI)
scripts/       # GDScript files (systems, data definitions)
resources/     # .tres data files (tiles, threats, seasons, events)
assets/        # sprites, audio, fonts
tests/         # GUT test files
design/        # Game Design Document
```

## Status

Early development — working toward a playable vertical slice (1 mountain, ~30-45 min run).
