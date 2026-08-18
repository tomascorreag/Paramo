# TODO

- [x] add ladders
- [x] add fences
- [x] improve icon system code
- [x] improve ground layering system

## Music

- [x] decide path: commission indie Colombian composer (~USD 800–2500, preferred) vs DIY with session musicians (~USD 400–950 + heavy DIY time) vs royalty-free libraries (fast, low authenticity)
- [x] scope soundtrack for vertical slice: ~7–9 min unique (menu, 3–4 biome/season ambient loops, 1–2 threat cues, planning-phase calm, win/loss stingers)
- [x] shortlist candidate composers from Bandcamp / SoundCloud / "nueva música andina colombiana" scene; check U. Antioquia / Javeriana / Unipamplona alumni

## Performance (flagged by super-review 2026-04-24)


## Web export hardening (from 2026-04-22 security review)

- [x] when creating `export_presets.cfg`, set Export Filter to exclude `addons/gut/*`, `tests/*`, `scripts/tools/*`, `*.md`, `design/*` — done except `scripts/tools/*`, which must stay in: `gameplay_base.tscn` / `procedural_base.tscn` / `frailejon.tscn` load runtime scripts from there. `*.md` and `design/*` never shipped (`export_filter=all_resources` takes resources only). Verified against the export's own `Storing File:` log, not a `strings` dump of the pck — see CLAUDE.md.
- [x] ensure web preset is Release (not Debug) and has no `--remote-debug` flag — CI runs `--export-release`, preset carries no debug template or debug flag
- [x] pick a web host that supports COOP/COEP headers (itch.io, Netlify, Cloudflare Pages) — GitHub Pages won't work because Godot 4 threaded builds need `Cross-Origin-Opener-Policy: same-origin` + `Cross-Origin-Embedder-Policy: require-corp` for `SharedArrayBuffer`. Alternative: disable threads in the export.
- [x] Clean up: fix and optimize processes that might be hacky/unoptimized, not only in the game but for the repo in general. Make sure not to downgrade any functionality. — 2026-08-11: `TileKindIndex` warning spam 262 → 2 per run (the "declared but unpainted" check asked a question one source cannot answer; replaced by a union test over the shipped tileset); export stopped bundling its own output (`docs/*`, `preview_out/*`, `sim_out/*`) — pck −8.3%; GUT now runs in CI on every branch/PR and gates the deploy; two orphan `.uid` files removed; the two root `code-review-*.md` deleted (superseded by `dev-notes/`); three undocumented tools documented; `CLAUDE.md` un-ignored and published. 775 tests green before and after.
- [x] make the pause and journal views completely pause the world, including effects like rain , fire and visitors, both functionally and visually.
- [x] Make grass tile degradation more of a continuous thing, with grass growing longer over time or shorter with degradation until it's gone. The max grass length should be the one that is currently assigned randomly during terrian generation, and the grass type should be maintained throughout (i.e. there are two tones of grass atm, which should be maintained).
- [x] add a fullscreen toggle to the in-game settings — a button in the pause menu's settings section, labelled with the action it performs (`fullscreen` / `windowed`); it drives `DisplayManager.toggle_fullscreen()` and re-reads the window mode while the menu is open so F11 and the window manager stay in sync. Panel grown 104 → 124px; two new layout guards in `test_locale_manager.gd`.
- [x] Reduce the damage visitors/player do while walking by 50%.
- [x] Add small cost icons to the items in the shop.
- [x] review the latest commit and current diff for bugfixes, improvements and optimizations.
