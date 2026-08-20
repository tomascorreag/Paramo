# UI chrome

Notes on the screen-space UI that is not the journal. The journal's own pages,
and the title screen's language gate, are in [journal.md](journal.md).

## Pause modal — `scripts/tools/preview_pause_menu.gd`

Renders all three views of `scenes/ui/pause_menu.tscn` in both locales:
`0_main_*` (the settings column), `2_about_*` (credits + licence links),
`4_confirm_*` (the quit guard).

```bash
... --script res://scripts/tools/preview_pause_menu.gd -- --out preview_out/pause
```

Needs a rendering context — do **not** pass `--headless`.

- **The panel does not grow to its content.** `Margin` is *anchored* to the panel
  rect rather than being a container child, so `Panel.custom_minimum_size` **is**
  the content box: a view taller than it is drawn outside the frame, silently.
  Only one view is visible at a time, so the **tallest** view sets the number —
  About, at 128px of a 130px budget (184x150 panel, 10px margins). Adding a row
  to any view means re-running `test_locale_manager.gd`, which prints both the
  needed and the available height.
- **`_set_view` also swaps the header key** (`TITLE_KEYS`), so a new view needs
  an entry there or the title keeps the previous view's word.
- **Show it with `visible = true`, not `open()`, in a tool** — `open()` sets
  `get_tree().paused`, which stops the tool's own `_process`. And do it from
  `_process`, not `_initialize`: the scene's `_ready` runs after `_initialize`
  and sets `visible = false`.
- **The language button's label does not follow the locale.** It is literal text
  (the *other* language's native name), refreshed by hand off
  `LocaleManager.locale_changed` — a tool that sets the locale through
  `TranslationServer` directly must call `_refresh_language_label()` itself.

### The About view

It exists so the licences are reachable from inside the game: Paramo is MIT, but
the deployed build carries AGPL (Strudel) and MIT-with-required-notice (FluidR3)
works, and `THIRD-PARTY-NOTICES.md` is the document that says so. The three
buttons deep-link to the repo, `LICENSE` and `THIRD-PARTY-NOTICES.md` on `main`.

- **`OS.shell_open` is the whole link mechanism, on both platforms.** On web it
  lands on `godot_js_os_shell_open`, i.e. `window.open(uri, "_blank")`. A browser
  may still refuse that as a popup, because Godot dispatches the button press
  from its own frame rather than from inside the DOM click handler — so the repo
  URL is **also printed as plain text** in the panel. Removing that label turns a
  blocked popup into a dead end.
- The author line and the URL are **literal** text, not translation keys: a name
  and an address have nothing to translate. They still follow the lowercase-chrome
  convention.
- **Link targets are tested against the files in the repo**
  (`test_about_links_point_at_the_licence_documents`). Renaming `LICENSE` or
  `THIRD-PARTY-NOTICES.md` breaks the in-game links, and that test is what says so.
