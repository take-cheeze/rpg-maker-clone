# 67. WOLF RPG Editor Picture(150) command: text pictures

Date: 2026-09-06

## Status

Accepted

## Context

WOLF RPG Editor has no native message window, choice window, or menu
widget: the editor-bundled "RPG Basic System" draws all of that itself,
using the same single, heavily-overloaded event command every real
project's own custom UI also uses -- **Picture (150)**. Until this command
does something, nothing built on top of the interpreter (ADR 0065, 0066)
can ever become visible beyond bare geometry and colour-block markers,
which made it the natural next milestone once map events landed.

No genuine `Game.exe`/wine harness exists for WOLF RPG Editor, and unlike
every command implemented so far, Picture's own argument layout is *not*
cross-confirmed by more than one independent source at the argument level:
WolfTL (a translation-extraction tool) only ever reads enough of the
command to find a translatable filename or string, never decoding
position/size/zoom/blend at all. Only the wolfrpg-map-parser Rust crate's
own from-scratch byte-level parser models those fields, so this command's
argument *positions* rest on that single source, cross-checked here only
empirically -- by feeding the crate's field names back against this
reader's own real command dumps from the sample game's "メッセージ
ウィンドウ" Common Event and confirming the values line up with what
`SetVariable` computed for them a few lines earlier in the same event
(e.g. a "division width/height" argument the crate's struct names for
sprite-sheet frame counts turns out, once cross-checked against the
scale-factor multiplication feeding it, to hold pixel width/height in this
project's own "window" picture calls -- not literally what the crate's
field name suggests for the plain-file case).

## Decision

`Wolf::Interpreter#exec_picture`, dispatched from `Run#dispatch`'s new
`C_PICTURE` case (previously lumped into the shared `unimplemented` list):

- **The mode bitmask** (`arg(0)`) is decoded in full and *is*
  cross-confirmed: the crate's own independent `Options`/
  `DisplayOperation`/`DisplayType`/`BlendingMethod`/`Anchor`/`Zoom`
  enums agree with WolfTL's own (narrower) `Type()` accessor and with
  the manual's own ピクチャ page, all in the same order -- operation
  (show/move/erase/delay-reset), display type (file/file-by-variable/
  text/window-file/window-by-variable), blend mode, anchor point, zoom
  mode, and the range/free-transform flags.
- **Erase** (operation 2) is fully implemented for every display type:
  it only ever needs the picture number, the one part of the argument
  layout that is unambiguous regardless of which single-source field
  order is right.
- **Show and Move** are implemented only for the plain "Base" case (no
  `range`, no `free_transform` -- those flags add extra corner/repeat
  fields this reader has not reverse-engineered) and only for the
  `text` ("string as picture") display type: the picture's on-screen
  text comes straight from the command's own string argument (like
  `Message`), sidestepping the file/window display types' own separate
  open questions (WOLF RPG Editor's Picture-folder convention, and
  9-slice window-graphic stretching). `file`/`file-by-variable`/
  `window-file`/`window-by-variable` all log an explicit "not
  implemented" warning and no-op, rather than rendering something
  wrong from an argument layout that isn't independently confirmed.
  Move animates nothing -- WOLF's own gradual fade/slide
  ("process_time" frames) is not modeled; both operations snap
  immediately, a documented simplification rather than a guess at
  exactly how that timing interacts with the calling event's own Fiber.
- **Rendering hook**: `Interpreter` gains a `current_scene` accessor
  (set by `WolfRPG#build_start_scene`, mirroring `current_map`) so
  `exec_picture` can call `WolfRPG::MapScene#show_string_picture`/
  `#erase_picture` without owning any RGSS objects itself -- the same
  separation of concerns `current_map`'s own doc comment describes.
  `MapScene` keeps one real `RGSS::Sprite`/`RGSS::Bitmap` pair per
  picture number in a dedicated, never-panned `@picture_viewport`
  (pictures are screen-space UI, not map-space geometry, so they must
  not scroll with the camera the way tiles/hero/events do), using
  `RGSS::Sprite`'s own native `zoom_x=`/`zoom_y=`/`angle=`/`opacity=`/
  `blend_type=` rather than reimplementing `mruby-rpg2k`'s own
  software-composited picture engine (RPG2000 predates RGSS's richer
  per-sprite properties, so its own Picture code has to manage a single
  shared bitmap and blit tone/zoom by hand -- WOLF's pictures need none
  of that, since real per-sprite zoom/angle/blend/tone are already
  native here).
- `RGSS::Font.default_path ||= RGSS.default_font_path` is now set at
  boot (`WolfRPG#initialize`), the same opt-in `mruby-rpgxp`/
  `mruby-rpgvx` already make, so text pictures (and any future real
  message window) have an actual TrueType face to draw the sample
  game's Japanese text with, rather than a bare "Arial" fallback with
  no CJK glyphs.

## Consequences

- A WOLF RPG Editor project can now show and erase text-only pictures
  with real position, opacity, zoom, angle and blend, driven by real
  Common Event/map-event commands -- the first command in this engine
  whose visible output is anything but bare geometry or a stderr log
  line.
- File- and window-based pictures -- which is what the sample game's own
  message window and menu actually use for their outer frame -- are
  still explicit no-ops. Extending this to `file`/`file-by-variable`
  needs WOLF's own Picture-image folder convention pinned down first;
  `window-file`/`window-by-variable` additionally need a 9-slice
  stretch (a natural fit for `RGSS::Window`'s own windowskin rendering,
  researched but not yet wired in, rather than a second, bespoke
  stretch implementation).
- The argument layout beyond the mode bitmask rests on a single source
  (the wolfrpg-map-parser crate) rather than the two- or three-source
  agreement every other command implemented so far has had; if it turns
  out wrong for some field, only the `text` display type's fully-
  implemented path (position/opacity/zoom/angle) is at risk, not the
  bitmask decode itself.
- `range`/`free_transform` Picture variants remain unimplemented no-ops;
  Move's own gradual animation is not modeled (every change snaps).
  Both are explicit follow-ups, listed in `docs/TODO.md`.
