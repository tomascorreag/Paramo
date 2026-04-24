# TODO

- [x] add ladders
- [ ] add fences
- [x] improve icon system code
- [x] improve ground layering system

## Music

- [ ] decide path: commission indie Colombian composer (~USD 800–2500, preferred) vs DIY with session musicians (~USD 400–950 + heavy DIY time) vs royalty-free libraries (fast, low authenticity)
- [ ] scope soundtrack for vertical slice: ~7–9 min unique (menu, 3–4 biome/season ambient loops, 1–2 threat cues, planning-phase calm, win/loss stingers)
- [ ] shortlist candidate composers from Bandcamp / SoundCloud / "nueva música andina colombiana" scene; check U. Antioquia / Javeriana / Unipamplona alumni

## Web export hardening (from 2026-04-22 security review)

- [ ] when creating `export_presets.cfg`, set Export Filter to exclude `addons/gut/*`, `tests/*`, `scripts/tools/*`, `*.md`, `design/*`
- [ ] ensure web preset is Release (not Debug) and has no `--remote-debug` flag
- [ ] pick a web host that supports COOP/COEP headers (itch.io, Netlify, Cloudflare Pages) — GitHub Pages won't work because Godot 4 threaded builds need `Cross-Origin-Opener-Policy: same-origin` + `Cross-Origin-Embedder-Policy: require-corp` for `SharedArrayBuffer`. Alternative: disable threads in the export.
- [ ] re-run security review if adding save-file import, modding, networking, telemetry, or IAP
