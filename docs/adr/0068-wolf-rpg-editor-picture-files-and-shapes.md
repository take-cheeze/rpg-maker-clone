# 68. WOLF RPG Editor Picture(150): real files, sprite-sheet cropping, and procedural shapes

Date: 2026-09-06

## Status

Accepted

## Context

ADR 0067 implemented Picture(150)'s mode bitmask in full but only actually
rendered the `text` display type, leaving `file`/`file-by-variable`/
`window-file`/`window-by-variable` as explicit no-ops: the argument layout
beyond the bitmask rests on a single source (the wolfrpg-map-parser
crate), and two real open questions stood in the way of trusting it for
real images -- where a picture's filename resolves to on disk, and how a
"window" picture's file relates to `RGSS::Window`'s own 9-slice skin.

Dumping many more real `Picture` calls from the sample game's own Common
Events and map-event pages (not just Common Events, which is where the
earlier ADR's own cross-check came from) answered both questions, and
surfaced a third one this reader had not looked for at all:

- Every real filename argument already carries its own subfolder, e.g.
  `"SystemFile/TitleGraphic.png"`, `"CharaChip/Special_Tiga.png"`,
  `"EnemyGraphic/GD_Basilisk(Red).png"`, `"Fog_BackGround/....jpg"`,
  `"Picture/FaceGraphic_Edy.png"` -- all relative to the project's own
  `Data/` folder, which really does contain exactly those subfolders.
  There is no separate "Picture folder" convention to pin down; the
  string argument already *is* the path.
- The sample game's entire custom-drawn UI (its menus, HUD, save/load and
  equip screens -- none of it a native engine widget, since WOLF RPG
  Editor has none) turns out to be built almost entirely from `text`
  pictures (ADR 0067) plus a *documented* "hidden feature" of the window
  display type: typing a special string instead of a real filename draws
  a procedural shape instead of loading an image at all
  (help/04ev_picture.html's own "隠し機能 図形表示" section) --
  `<SQUARE>`/`<SQUARE>FRAME`, `<GRADX-AAA-BBB>`/`<GRADY-AAA-BBB>`
  (a two-colour gradient box, each colour a 3-digit 0-9-per-channel RGB
  code), and `<LINE>`/`<LINE-NN>`. `<CIRCLE>`/`<TRI-*>` are documented
  too but not used anywhere in the sample game's own data.
- The argument layout is not, in fact, a single fixed "Base" shape
  regardless of the other mode bits: a real `Move` call with zoom mode
  "same as current" carries 13 arguments where this reader's own
  (already-shipped, already-verified-for-`Show`) 11/12-argument
  hypothesis would predict 11 -- some sub-mode this reader has not
  reverse-engineered evidently changes which optional fields are
  present. Rather than guess at what that 13th argument means,
  `#exec_picture_show_or_move` now checks `cmd.args.size` against the
  expected count for the display type *before* trusting the slot layout
  at all, falling back to an explicit no-op on any mismatch. Every
  `Show` case implemented here was individually cross-checked against a
  real example with exactly the expected argument count, so this gate
  costs nothing on the confirmed path and only ever suppresses an
  unconfirmed one.

## Decision

- **Real file pictures** (`file`/`file-by-variable`): `WolfRPG::MapScene
  #show_file_picture` loads `Data/<the stored path>` via `RGSS::Bitmap`,
  applies position/opacity/zoom/angle/blend/anchor the same way text
  pictures already do, and crops to one cell of a `div_w`x`div_h`
  sprite-sheet grid (`src_rect`) when the picture's own division-count
  arguments call for it (a character sheet's animation frame), the whole
  image otherwise. A load failure (missing/corrupt file) is logged once
  and skipped rather than crashing event execution -- the same tolerance
  `run_common_event` already extends to bad data elsewhere.
- **Special file directives** (a filename string starting with `<`,
  e.g. `<SCREENSHOT>` -- also real in the sample game's own data, not
  documented anywhere this reader has found) are explicitly skipped
  rather than attempted as a literal (and inevitably missing) filename.
- **Procedural shape pictures**: `Interpreter#parse_shape_tag` decodes
  the window display type's special strings (fully documented, not
  reverse-engineered, so implemented with full confidence unlike the
  rest of this command); `MapScene#show_shape_picture` draws the result
  -- `<SQUARE>`/`FRAME` and the gradients via `RGSS::Bitmap`'s own native
  `fill_rect`/`gradient_fill_rect`, `<LINE>`/`<LINE-NN>` for the
  horizontal/vertical case the sample game's own UI actually uses (a
  genuinely diagonal line is not modeled -- not seen in real usage). A
  real window-skin file (a window-type picture whose string is not one
  of these tags) remains an explicit no-op; that still needs
  `RGSS::Window`'s own 9-slice stretch, not this shape-drawing path.
- **Move** (`PICTURE_OP_MOVE`) is now handled separately from Show: it
  never re-reads the picture's content (no file reload, no shape
  re-parse), only updates the already-shown sprite's transform --
  `MapScene#move_picture` reuses the anchor and box size the original
  Show call recorded, so a centre- or corner-anchored picture does not
  jump to a top-left interpretation on its first Move.

## Consequences

- Every one of the sample game's own file-based pictures (its title
  screen, NPC face graphics, character sprites, background images) and
  every one of its shape-drawn UI boxes/gradients/dividers now render
  for real, using the exact real command data that drove this
  cross-check -- confirmed by booting the compiled binary against the
  sample game with no crash and no "not implemented" warning for the
  title screen's own file picture, which loads silently now instead of
  logging.
- Real window-skin pictures (a literal file for the "window" display
  type, not a shape tag) are still unimplemented; so is `<CIRCLE>`/
  `<TRI-*>` (documented, not used by the sample game, and their fill
  algorithms are more involved than the rectangle/gradient primitives
  `RGSS::Bitmap` already provides natively) and a genuinely diagonal
  `<LINE>`.
- The argument-count gate this ADR adds is a general safety net, not
  specific to any one display type: any `Show`/`Move` call whose other
  mode bits (a "Colors" variant, a non-"Normal" zoom mode, ...) change
  the argument count from what is confirmed here falls through to an
  explicit no-op automatically, the same "log rather than guess"
  discipline every other command in this interpreter already follows.
