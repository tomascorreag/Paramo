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
- [ ] define very clearly the goal aesthetic experience of the player. Put simply: WHY are they  having fun?
- [x] add language toggle to settings.
- [x] Add about section to settings, include links to repo licenses and such. — a third view in the pause modal (`about` row in the settings column): author line, the repo URL as plain text, and three `OS.shell_open` links to the repo, `LICENSE` and `THIRD-PARTY-NOTICES.md`. Panel grown 124 → 150px, since about is now the tallest view; new `preview_pause_menu.gd` and five guards in `test_locale_manager.gd`. See [ui](dev-notes/ui.md).
- [x] make the instruments at the beginning take 4x longer to stagger in, meaning not wait one loop for each instrument but 4 loops. This is to cover the tutorial — `ADD_EVERY` in `docs/music/paramo-music.js` now defaults to 4 cycles instead of 1, so the seven layers of ojos_azules reach the full mix ~7 min in instead of ~1.8 min. Additions now land on the multiples of 4 where the melody plays complete, and `data-add-every` on the script tag still overrides it.
- [x] the "about" section says "por tomás correa" even when set to english. Make it "by" when in english, and also use capitalization for the name ("Tomás Correa") — the preposition is a CSV key (`UI_ABOUT_BY`) and the name stays a literal in code, composed by `_refresh_author()` off `NOTIFICATION_TRANSLATION_CHANGED`. Splitting the line is what keeps a capitalised proper noun out of the lowercase-chrome check, which scans the CSV. Same pass reshaped the modal: a back chevron for every submenu, a checkbox for fullscreen, a dropdown for language, and an `info` section for `about`. Panel grown 150 → 164px. See [ui](dev-notes/ui.md).
- [x] ignore hotkeys (like space key for journal) when paused — pausing the tree does not silence a `PROCESS_MODE_ALWAYS` node, and two of them were listening: Space opened the journal over the pause menu, any key burned an FTUE line. Both now check a `PauseMenu.is_blocking()` static flag (not `get_tree().paused` — the journal pauses too, and its own Space must still close it). New `test_pause_hotkeys.gd`. See [ui](dev-notes/ui.md).
- [x] fix fps stutter spike when fire comes on screen.
