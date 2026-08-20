# Páramo

An environmental strategy game built in **Godot 4.6** with GDScript.
Playable in the browser: **https://tomascorreag.github.io/Paramo/**

<img src="assets/screenshots/Screenshot%202026-04-16.png" alt="Build screenshot, April 2026" width="600">

## Premise

You are a field coordinator protecting a Colombian **páramo** — a high-altitude Andean ecosystem that functions as a natural water factory. Threats climb the mountain from below: miners, tourists, cattle, invasive species. Environmental hazards strike from all directions: drought, fire, erosion, climate shift.

The páramo operates on geological time. Humans destroy on industrial time. Your job is not to win — it's to endure.

## What's implemented

A run is playable end to end, from the title screen to the last season, on a mountain generated fresh each time.

**Run spine**
- Title screen with a language gate (en-GB / es-CO), asked every launch
- Procedurally generated isometric mountain per run — altitude bands, cliffs, ramps, a river reaching the south edge, biome-banded vegetation
- Season clock: 6 seasons per run, alternating wet/dry, 4 day/night cycles each. Seasons roll straight into one another; there is no planning phase
- Scripted FTUE for the opening minutes — narrative bracket, then move / journal / shop / build / douse, with each verb inert until the step that teaches it

**Simulation**
- Day/night cycle with dynamic lighting, ambient regrade per season, and a player-carried lantern
- Weather: rain intensity driven by the season profile, feeding both the water reserve and fire risk
- Fire: per-cell ignition and spread against live fuel, with an off-screen glow overlay reporting fires outside the frame
- Vegetation: continuous grass growth and wear per cell, trampling from walking, regrowth over time, dirt colonisation
- Visitors: recoloured walking agents that trample the ground, plus a daily eco-tourism income computed from rain and land appeal
- Wind, water flow and waterfall shaders, object shadows, altitude fog

**Player verbs**
- Click-to-move and WASD, over grid pathfinding that respects altitude and traversal legality
- Build ladders, bridges and fences; plant frailejones; remove any of them; extinguish fire; inspect a tile
- Two currencies: tokens (earned from visitors, spent to unlock a tool type and then per tile placed) and water (accrued from rain and fog capture, spent dousing fire and planting)

**UI**
- Field journal (Space): run calendar, season wheel, known-flora and known-works sets, the shop pages, tooltips, water readout
- HUD with an equipped-item radial picker, pause menu with settings and fullscreen toggle, debug overlay (F3)
- Full en-GB / es-CO localization, key-based, guarded by tests that measure both locales against the pixel budgets

**Toolchain**
- 48 GUT test files, run in CI on every branch and PR, gating the deploy
- Headless Monte Carlo balance simulator, terrain invariant sweeps, shader benchmarks, palette audits, preview renderers — see [`dev-notes/`](dev-notes/README.md)
- Web export to GitHub Pages with a vendored Strudel music engine

## Intended design, not yet built

From `design/Paramo_GDD.md`; none of this exists in code today.

- **10 seasons** per run (the current 6 is a scaffolding number), a planning phase between them, and an end screen with win/loss
- Threats beyond visitors and fire: illegal miners, cattle and farmers, invasive species, a legal-mining event, drought as a distinct pressure
- Resources beyond water and tokens: funding and community support
- A weighted seasonal event system (`resources/events/` is empty)
- Tools beyond ladders, bridges, fences and frailejones: trails, channels, signage, monitoring stations, the research station and its management UI
- Fog of war, monitoring-station reveal radii, the radio upgrade and its interaction tiers
- The glacial laguna at the summit as a real object with a drain and a loss condition

## Tech

- **Engine:** Godot 4.6.1 (Standard, not .NET) · GL Compatibility renderer
- **Language:** GDScript, statically typed
- **Art:** isometric pixel art (diamond tiles, 2:1), locked to a 33-colour palette
- **Display:** logical viewport 480×270 as a design reference; at runtime `DisplayManager` picks an integer upscale from the monitor and the window rasterizes at its own resolution. There is no SubViewport

## Running

The Godot executable is expected one directory up from the project root, inside a folder named `Godot_v4.6.1-stable_win64.exe/`.

```bash
G="../Godot_v4.6.1-stable_win64.exe/Godot_v4.6.1-stable_win64_console.exe"

$G --path .                                       # run the game (res://scenes/main.tscn)
$G --path . --scene res://scenes/maps/level1.tscn # one map directly
$G --path . -s addons/gut/gut_cmdln.gd            # tests

"../Godot_v4.6.1-stable_win64.exe/Godot_v4.6.1-stable_win64.exe" --path . --editor
```

Controls: **WASD** or mouse click to move · **Space** journal · **Esc** pause · **F11** fullscreen · **F3** debug overlay · **F** fast-forward and **M** end season (dev keys on the run controller).

## Project Structure

```
scenes/        # .tscn — entities, maps, templates, UI, objects, traversals, vfx
scripts/       # .gd — systems, data resources, ui/core, tools, debug
resources/     # .tres — tiles, seasons, terrain params, materials, UI theme
assets/        # sprites, audio, fonts, shaders, palettes, translations
tests/         # GUT tests
dev-notes/     # tool reference and measured findings
design/        # GDD (en/es), roadmap, moodboard
music/         # Strudel arrangements + score converter
```

Working conventions, tool reference and the measured findings behind the tuning numbers are in [`CLAUDE.md`](CLAUDE.md) and [`dev-notes/`](dev-notes/README.md).

## Status

Vertical slice in progress. The run loop, economy, fire and vegetation systems are live; threats, events and the win/loss frame are not. See `design/Paramo_GDD.md` for the full design.
