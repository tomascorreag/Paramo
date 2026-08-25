# UI chrome

Notes on the screen-space UI that is not the journal. The journal's own pages,
and the title screen's language gate, are in [journal.md](journal.md).

## Pause modal — `scripts/tools/preview_pause_menu.gd`

Renders every view and widget state of `scenes/ui/pause_menu.tscn` in both
locales: `0_main_*` (the settings + info sections), `2_about_*` (credits +
licence links), `4_confirm_*` (the quit guard), `6_lang_*` (the language
dropdown, open) and `8_check_en` (the fullscreen checkbox ticked — the tool runs
windowed, so that one state is forced by hand).

```bash
... --script res://scripts/tools/preview_pause_menu.gd -- --out preview_out/pause
```

Needs a rendering context — do **not** pass `--headless`.

- **The panel does not grow to its content.** `Margin` is *anchored* to the panel
  rect rather than being a container child, so `Panel.custom_minimum_size` **is**
  the content box: a view taller than it is drawn outside the frame, silently.
  Only one view is visible at a time, so the **tallest** view sets the number —
  Main, at 133px of a 144px budget (184x164 panel, 10px margins), since the
  settings/info split overtook About (108px). Adding a row to any view means
  re-running `test_locale_manager.gd`, which prints both the needed and the
  available height.
- **`_set_view` also swaps the header key** (`TITLE_KEYS`), so a new view needs
  an entry there or the title keeps the previous view's word.
- **Show it with `visible = true`, not `open()`, in a tool** — `open()` sets
  `get_tree().paused`, which stops the tool's own `_process`. And do it from
  `_process`, not `_initialize`: the scene's `_ready` runs after `_initialize`
  and sets `visible = false`.
- **The language row's value does not follow the locale.** It is literal text
  (the active language's own native name), refreshed by hand off
  `LocaleManager.locale_changed` — a tool that sets the locale through
  `TranslationServer` directly must call `_refresh_language_row()` itself.

### The widgets

Three of the modal's controls are hand-built rather than taken from Godot's
widget set, and each was rejected for a concrete reason:

- **Fullscreen is a checkbox**, so the row names the setting and the box carries
  its value. `CheckBox` would have needed its own check glyph drawn into the icon
  sheet and registered as a theme icon, and would still not carry the panel's
  frame. The box is instead `solid_surface` + `frame_border` at **10x10** — the
  frame's authored size, which is why it is not 8x8 — with a `solid_accent` fill
  inset 3px that is simply hidden when off. The fill is the **bright** accent
  (P12) on purpose: `solid_accent_soft` is the same tone as the frame, and at 4x4
  the two states were indistinguishable.
- **Language is a dropdown**, a Panel inside the modal rather than an
  `OptionButton`. That widget opens a `PopupMenu` — a separate `Window` with its
  own theme items (none of which `paramo_theme.tres` styles) that does not
  inherit this CanvasLayer's integer upscale. The list is built at runtime from
  `LocaleManager.SUPPORTED`, so a third locale needs no edit to the scene, and it
  is sized and placed from the row it drops out of **every time it opens** — the
  panel lays out on the frame after a view swap, so baked geometry is stale on
  first show.
- **A submenu's way back is the chevron anchored to the panel's top-left**, not a
  row inside the view: same place in every submenu, and it costs the view no
  height. `_set_view` derives its visibility (`v != View.MAIN`), so a view added
  later is escapable without touching that line. Esc still backs out too, and it
  now closes the dropdown first — the innermost thing open goes first.

**A Container resets a child's `rotation` (and `scale`) every layout pass.** The
dropdown's chevron is the back chevron turned 90°, and inside the `HBoxContainer`
it silently rendered unrotated. The fix is a plain `Control` wrapper that the
container sizes, with the rotated `TextureRect` anchored inside it.

### Hotkeys under the modal

`get_tree().paused` does not silence hotkeys. It silences most of them, because the SceneTree skips input on a node that cannot process — but every node that must stay alive under pause runs `PROCESS_MODE_ALWAYS`, and those keep hearing keys behind the modal. Two did: Space threw the journal open on top of the pause menu, and any key advanced an FTUE narrative line the player never read.

- **The test is `PauseMenu.is_blocking()`, not `get_tree().paused`.** The journal pauses the tree as well, and its own Space must still close it. The flag is a `static var` on `PauseMenu`, set in `open()`/`close()` and cleared in `_exit_tree()` — same shape and same per-process caveat as `TutorialGate`. The `_exit_tree` clear is what covers the desktop quit path, where `reload_current_scene()` frees the modal without closing it.
- **A gated handler returns without consuming the event.** The key belongs to the pause menu; swallowing it would eat Esc.
- **Any new `PROCESS_MODE_ALWAYS` node that reads input needs the guard** — pausable nodes get it for free. `test_pause_hotkeys.gd` pins both halves of that engine behaviour, so the assumption is checked rather than remembered.
- `DisplayManager`'s F11 is deliberately **not** gated: the modal has its own fullscreen row and polls the window mode every frame, so the two agree either way.

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
- **The author line is half copy and half proper noun.** "by Tomás Correa · 2026"
  is a preposition that translates (`UI_ABOUT_BY` → "por") in front of a name that
  does not and is capitalised. The whole line cannot be one CSV row: the
  lowercase-chrome check in `test_localization.gd` scans the CSV and knows nothing
  about names. So the key holds the preposition, `PauseMenu.AUTHOR` holds the
  name, and `_refresh_author()` composes them — which costs the label its
  automatic re-translation, hence the `_notification` hook. The URL is literal for
  the simpler reason that an address has nothing to translate, and it still
  follows the lowercase convention.
- **Link targets are tested against the files in the repo**
  (`test_about_links_point_at_the_licence_documents`). Renaming `LICENSE` or
  `THIRD-PARTY-NOTICES.md` breaks the in-game links, and that test is what says so.
