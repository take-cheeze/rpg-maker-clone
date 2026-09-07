# 84. WOLF RPG Editor Effect(290) Picture Flash, and a native Viewport#update gap

Date: 2026-09-07

## Status

Accepted

## Context

`Flash`(effect_type 0, "フラッシュ") is next by real frequency within
`Effect`(290)'s Picture target after `SwitchFlicker` (ADR 0083) -- 10 real
calls, all with a genuine non-zero `duration` -- and, like `SwitchFlicker`,
fully confirmed by the wolfrpg-map-parser crate's own `PictureEffectType`
enum (`Flash = 0x00`). help/04ev_effect.html documents it as a one-shot
additive colour pulse: "指定した赤・緑・青の値をピクチャの「カラー」に加
算して1回だけフラッシュします。±200までの値に対応。" -- add the given RGB
to the picture's own colour, once, fading over `arg(1)`'s own frame count
(the same "this field is a genuine frames value here, not the unsupported
delay the two instant effect kinds use it as" exception `SwitchFlicker`
already established).

Unlike `SwitchFlicker`, this needs no Ruby-side persistent state at all:
native RGSS `Sprite#flash(color, duration)` already implements exactly
this -- a timed colour overlay that decays and clears itself -- and every
Wolf picture is already a real `Sprite`. The only piece missing was
wiring: `Sprite#flash`'s own decay (`mruby-rgss/src/lib.cxx`'s own
`spr_update`) only advances when something calls `Sprite#update` once per
frame, which nothing in this reader's Picture code did yet.

Chasing that exact wiring question turned up a second, older gap in the
same family: `ChangeColor`(151)'s own "flash" case (ADR 0079,
`WolfRPG::MapScene#change_color`) already calls native `Viewport#flash`,
but nothing in this reader ever calls `Viewport#update` either --
`vp_update`'s own native comment ("One frame: advance a running flash and
repaint the overlay...") makes the same requirement explicit for
`Viewport` that `spr_update`'s does for `Sprite`. Without it, a real
`ChangeColor` flash call would set the overlay once and then freeze there
forever (never fading back to normal), since nothing else re-triggers the
native repaint that reads the decaying `@flash_count`. `#update_tone`'s own
direct `@viewport.tone = ...` writes are unaffected (a `tone=` assignment
repaints on its own), so this was specific to the flash case alone, and
had no automated test exercising it either way (ADR 0079's own
Consequences already flagged the native flash/tone path as reviewed by
hand rather than exercised end-to-end).

## Decision

- `Wolf::Interpreter#exec_effect` gains `EFFECT_PICTURE_FLASH = 0`,
  dispatched (alongside `SwitchFlicker`) before the shared "delay must be
  0" gate that still applies, unchanged, to `DrawPositionShift`/
  `ColorCorrect`. Reads `arg(1)` as the flash's own duration and
  `arg(4..6)` as the RGB delta, across the same real contiguous
  `first..last` picture-number range every other Picture effect kind
  already uses.
- A new `WolfRPG::MapScene#flash_picture(number, r, g, b, duration)` calls
  `entry[:sprite].flash(color, duration)` directly -- no state kept here,
  unlike `#tint_picture`'s persistent addition to the sprite's own base
  colour, since the native flash is its own independent, self-clearing
  overlay.
- `#update_picture_effects` (already ticked once per frame for
  `SwitchFlicker`, ADR 0083) now unconditionally calls
  `entry[:sprite].update` for every live picture first, so a flash
  actually decays regardless of whether that same picture also has an
  active flicker.
- `WolfRPG::MapScene#update` now also calls `@viewport.update`, fixing the
  `ChangeColor`(151) flash-freezes-forever gap found above.

## Consequences

- Verified by two new CRuby-level tests (a real call resolving
  duration/RGB/range correctly, and a range/nil-scene tolerance check),
  the CRuby harness (121 assertions, 0 failed), `ctest -R mruby_test`
  (crash count held at the pre-existing 19-crash baseline), the testbed
  and interpreter soak checks, and the compiled binary against the real
  sample game.
- `Sprite#flash`/`Viewport#flash`'s own native decay still could not be
  exercised end-to-end by any of the above the way the interpreter-level
  dispatch could: the soak/testbed checks run without a real
  `current_scene`, so only "which scene method gets called, with which
  resolved arguments" is exercised automatically, the same limitation
  already noted for `SwitchFlicker`/`ChangeColor`'s own native paths.
  Reviewed by hand against `mruby-rgss/src/lib.cxx`'s own `spr_update`/
  `vp_update` instead.
- Still unimplemented: every remaining Picture effect kind (Shake, Zoom,
  SwitchAutoFlash, AutoEnlarge, the auto-pattern-switch family), the
  Character and Map targets entirely, and `duration`/delay > 0 for the two
  already-implemented one-shot kinds (`DrawPositionShift`/`ColorCorrect`).
