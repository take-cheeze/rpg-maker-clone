# 79. WOLF RPG Editor ChangeColor(151)

Date: 2026-09-07

## Status

Accepted

## Context

`ChangeColor`(151), WolfTL's own name, is next by real frequency after
`Checkpoint`(99) in the corrected census (10 occurrences). help/
04ev_effect.html's own "色調変更" section (part of the same manual page as
`Effect`(290), but its own separate WOLF command code) documents it:
"画面内のRGB（赤・緑・青）それぞれの色調を変化させます。0が最小値で、200
が最大値、100が通常の値です。「フラッシュにする」をチェックすると、フレ
ーム数の間だけその色で画面を光らせます" -- unlike `Effect`(290)'s own
Picture-target effects (an additive delta on top of whatever a picture
already has), `ChangeColor`'s own RGB values are *absolute*: 0 the
darkest, 100 neutral, 200 the brightest. A `flash` checkbox switches the
same three RGB fields from a persistent tone change to a one-shot timed
overlay flash instead.

The wolfrpg-map-parser crate's own `ChangeColor` struct (`red: u8, green:
u8, blue: u8, flash: bool, duration: u32`) maps directly onto this
reader's `arg(N)` framing -- every one of the 10 real calls carries
exactly 2 arguments, `arg(0)`'s four bytes the RGB/flash fields, `arg(1)`
the duration -- decoded and cross-checked against the manual's own
documented UI presets (色リセット "reset" = 100/100/100, 真っ暗に "pitch
black" = 0/0/0, both present verbatim in real data). Critically, real
duration is *never* 0 (10-40 frames every real call), meaning the visible
effect is a genuine, gradual transition -- not an instant set the way
`Effect`(290)'s own confirmed Picture effects turned out to be. This
codebase has no prior "animated screen tone" precedent for any engine to
mirror (checked `mruby-rpg2k`/`mruby-rpgxp`, neither has one), so this is
new, purpose-built machinery, not a reuse of an existing pattern.

RGSS provides exactly the two native primitives this needs, confirmed
already used elsewhere in this codebase (`mruby-rpgxp`'s own animation
timing code calls `self.flash`/`self.viewport.flash`): `Viewport#flash
(color, duration)`, a one-shot overlay with its own native timed decay
(no extra state needed here at all), and `Viewport#tone=`, an instant
rescale with no built-in animation -- RPG Maker's own scripted engines
animate a tone change in Ruby (`Game_Screen#start_tone_change`), not
natively, so this reader does the same.

## Decision

- `Wolf::Interpreter#exec_change_color` decodes the packed word and
  duration, delegating to a new `WolfRPG::MapScene#change_color(r, g, b,
  flash, duration)`.
- `flash: true` maps straight to `Viewport#flash`, scaling WOLF's own
  [0, 200] range onto `Color`'s 0-255 channels (0 contributes nothing,
  200 full intensity) -- the manual's own tone semantics (100 = neutral)
  do not apply to a flash overlay, which has no "darken" concept at all.
- `flash: false` starts (or redirects, always from the viewport's own
  *current* tone, never a queued prior target -- the manual always
  describes the visible, current state) a linear transition of
  `@viewport.tone` toward the target over `duration` frames, ticked once
  per frame by a new `#update_tone` (mirroring the existing per-frame
  tick pattern `#update_event_movement`/`#tick_ambient_move` already
  use for character movement); `duration <= 0` snaps instantly. WOLF's
  own [0, 200]/100-neutral scale maps onto RGSS `Tone`'s own signed
  -255..255 delta-from-neutral channel via `(v - 100) * 255 / 100`,
  exact at both endpoints and the neutral midpoint.

## Consequences

- The sample game's own real `ChangeColor` calls (map-event pages on
  maps 1-3, none in Common Events) now run for real -- verified against
  all 10 real calls replayed directly with a fake scene (0 exceptions,
  decoded values matching the manual's own documented presets exactly),
  the soak check, and `ctest -R mruby_test` (crash count held at the
  pre-existing 19-crash baseline). The compiled binary's own 10-second
  boot against the sample game did not reach a map event carrying this
  command (the title screen's own choice prompt blocks further progress
  without simulated input), so the native `Viewport#flash`/`#tone=`
  call surface itself was not exercised end to end this pass -- it is
  the same well-established RGSS API `mruby-rpgxp`'s own animation code
  already calls elsewhere in this codebase, and this native build's own
  test suite already probes `Viewport#tone`/`#color` (the "RGSS-PROBE"
  checks in `mruby-rgss/mrblib/lib.rb`).
- This is the first "animated over N frames" screen-level effect this
  reader implements; the same `#update_tone`-style per-frame-tick
  pattern is the natural template for a future `Effect`(290) Picture
  Flash/Shake/blink implementation, none of which this reader has yet.
