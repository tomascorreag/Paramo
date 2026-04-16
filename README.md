# Páramo

An environmental strategy game built in **Godot 4.6** with GDScript.

<img src="assets/screenshots/Screenshot%202026-04-16.png" alt="Current build" width="600">

## Premise

You are a field coordinator protecting a Colombian **páramo** — a high-altitude Andean ecosystem that functions as a natural water factory. Threats climb the mountain from below: miners, tourists, cattle, invasive species. Environmental hazards strike from all directions: drought, fire, erosion, climate shift.

The páramo operates on geological time. Humans destroy on industrial time. Your job is not to win — it's to endure.

## Gameplay (target)

- **10 seasons** of planning and real-time defense on a single handcrafted isometric mountain
- Plant frailejones, build trails, fences, channels, and monitoring stations
- Manage 3 resources: water, funding, and community support
- Physically traverse the mountain — altitude affects movement, growth, and exposure
- Protect the glacial laguna at the summit. If it dies, everything dies.

## Current State

Early prototype / tileset sandbox. Running the main scene gets you:

- Isometric tile grid with multi-layer Y-sorted terrain
- Click-to-move player with grid pathfinding
- Day/night cycle with dynamic lighting and player-carried light
- Wind system with grass and terrain interaction
- Water flow and waterfall shaders
- Object shadows
- Frailejón planting interaction
- Tile debug overlay / UX overlay

No seasons, threats, resources, or win/loss yet — those are the vertical-slice milestone.

## Tech

- **Engine:** Godot 4.6.1 (Standard, not .NET)
- **Language:** GDScript
- **Art:** Isometric pixel art (diamond tiles, 2:1 aspect)
- **Resolution:** 384x216 native, scaled 3x

## Running

The Godot executable is expected one directory up from the project root, inside a folder named `Godot_v4.6.1-stable_win64.exe/`.

```bash
# Run the main scene (res://scenes/main.tscn, configured as project main)
"../Godot_v4.6.1-stable_win64.exe/Godot_v4.6.1-stable_win64_console.exe" --path .

# Open in editor
"../Godot_v4.6.1-stable_win64.exe/Godot_v4.6.1-stable_win64.exe" --path . --editor

# Run a specific scene instead
"../Godot_v4.6.1-stable_win64.exe/Godot_v4.6.1-stable_win64_console.exe" --path . --scene res://scenes/tools/tileset_test.tscn
```

Controls: **WASD** to move, mouse click to path to a tile.

## Project Structure

```
scenes/        # .tscn scene files (entities, tools, UI)
scripts/       # GDScript files (systems, data definitions)
resources/     # .tres data files (tiles, materials, shaders)
assets/        # sprites, audio, fonts
tests/         # GUT test files
```

## Status

Early development — working toward a playable vertical slice (1 mountain, ~30-45 min run). See `Paramo_GDD.md` for the full design.
