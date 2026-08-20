# dev-notes

Tool reference and measured findings, split out of `CLAUDE.md` (which was 2158
lines and loaded into every session). CLAUDE.md keeps the rules and a one-line
hook per finding; the detail — *why* a number is what it is, and which
experiments were already run and failed — lives here.

Every command assumes the project root as cwd and this executable:

```
"../Godot_v4.6.1-stable_win64.exe/Godot_v4.6.1-stable_win64_console.exe"   # CLI
"../Godot_v4.6.1-stable_win64.exe/Godot_v4.6.1-stable_win64.exe"           # GUI/editor
```

| File | Covers |
|---|---|
| [terrain.md](terrain.md) | Procedural generation harnesses, tileset atlas copy, scene baking |
| [vfx.md](vfx.md) | Rain shader, blob fire, off-screen fire aura |
| [journal.md](journal.md) | Field journal: page warp, calendar, known sets/shop, language gate |
| [tiles.md](tiles.md) | Tile ink measurement, fences |
| [ui.md](ui.md) | Screen-space chrome: the pause modal and its about/licence view |
| [ftue.md](ftue.md) | Opening day: start time, first-day fire grace, the tutorial strip |
| [visitors.md](visitors.md) | Visitor sheets, recolour, parties, routing behaviour |
| [vegetation.md](vegetation.md) | Regrowth/trample: one value per cell |
| [performance.md](performance.md) | Every profiler and benchmark, and what they found |
| [balance-sim.md](balance-sim.md) | Monte Carlo balance simulator |

**Reading a finding:** anything marked MEASURED was really run. Findings that
say an idea was *rejected* are there to stop it being rebuilt — read those
before proposing the optimisation they describe.
