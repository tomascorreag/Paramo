# Vendored drum samples

Percussion for `ojos_azules.strudel.js`, served from this repo instead of fetched
from a CDN at play time. See `THIRD-PARTY-NOTICES.md` for the licence entry.

## Why these are here

`paramo-music.js` used to call `S.samples()` against `strudel.b-cdn.net`, whose
manifests in turn pointed at `raw.githubusercontent.com` — two third parties in
every player's browser, with no integrity check and nothing to fall back on if
either went away. Vendoring removes both.

## What is here

`uzu-drumkit/` — the six sample keys the arrangement plays, all variants of each:

| Key | Used by | Variants |
|---|---|---|
| `bd` | `bombo` (the anchor kick) and the `accents` pickup | 8 |
| `sd` | `ticks` (the wood gallop) | 5 |
| `cr` | `accents` (the loop-opening crash) | 2 |
| `oh` | `accents` (open hat on the downbeat) | 4 |
| `rd` | `accents` (ride) | 1 |
| `sh` | `sesq` (the sesquialtera shaker) | 1 |

21 files, 1.58 MiB. **All variants** are vendored, not just the first of each:
the song writes `sound("bd")` with no explicit `.n()` index, and shipping only
index 0 would mean any change to how Strudel resolves an unindexed name silently
drops a percussion layer — a failure that shows up in the deployed build and
nowhere else.

`uzu-drumkit.json` is a local manifest in the same shape as the upstream one,
minus its `_base` (the base URL is passed as `S.samples`' second argument, which
overrides it).

## Licence

**uzu-drumkit — The Unlicense (public domain).**
<https://github.com/tidalcycles/uzu-drumkit>

The `AkaiMPC60` kick the bombo used to load from `tidal-drum-machines` is
deliberately **not** here: that pack grants no licence and carries inMusic
trademarks. The bombo plays an unbanked uzu `bd` instead.

## Refetching

Paths come from the upstream manifest; each file is that repo's raw URL:

```
manifest: https://strudel.b-cdn.net/uzu-drumkit.json
files:    https://raw.githubusercontent.com/tidalcycles/uzu-drumkit/main/<path from the manifest>
```

## `.gdignore`

The empty `.gdignore` beside this file is required, not incidental. This
directory sits under `res://`, so without it Godot imports all 21 WAVs as
`AudioStreamWAV`, littering `.import` files here and filling the `.godot` cache
with assets the game never loads — the same class of problem as the export
bundling its own output (see `CLAUDE.md`). Keep it scoped to this directory:
a `.gdignore` at `docs/` would un-import the PWA icons, which are real imports.
