# 85. WOLF RPG Editor Effect(290) Picture Shake

Date: 2026-09-07

## Status

Accepted

## Context

`Shake`(effect_type 3, "シェイク") is next by real frequency within
`Effect`(290)'s Picture target after `Flash`/`SwitchFlicker` (ADR 0083/
0084) -- 4 real calls -- and, like both of those, fully confirmed by the
wolfrpg-map-parser crate's own `PictureEffectType` enum (`Shake = 0x03`).
It ties with the Map target's own `Zoom` (also 4 real calls) by frequency,
but `Zoom` needs a whole-camera transform this reader's single map
`@viewport` has no native support for surveyed yet, a meaningfully larger
architectural question than another per-picture effect; `Shake` was
picked as the smaller, better-scoped next step, extending infrastructure
(`#update_picture_effects`) this pass already has.

help/04ev_effect.html documents it as "指定したX、Yの移動分で、指定回数だ
けピクチャを揺らします。「処理時間」フレームが短いほど、高速に振動しま
す。10万回以上にすると無限になります。" -- shake the picture by a given
(X, Y) displacement, a given number of times, the same "duration is a
genuine frames value, not the unsupported delay the two instant effect
kinds use it as" exception `Flash`/`SwitchFlicker` already established for
`arg(1)` (here, how many frames per shake step). The one real call's own
`value1`/`value2`/`value3` (`[0, 1, 999999]`) line up with this reading
precisely: `dx=0, dy=1`, and a count of 999999 that matches the manual's
own explicit "≥100,000 becomes infinite" note almost exactly.

The manual does not say whether "指定回数だけ...揺らします" (shakes it the
specified number of times) counts one displacement away from center as a
shake, or a full round trip back to center -- and the one real call's own
near-infinite count cannot distinguish either reading, since it never
exhausts in practice either way. This reader picks "one displacement away
from center is one shake," the more literal reading of the phrase, and
flags it here as an assumption rather than a real-data-confirmed fact,
the same honesty ADR 0082's own `is_pointer` section and ADR 0080's own
`Teleport` non-hero-target gap already model for a gap real data cannot
close.

## Decision

- `Wolf::Interpreter#exec_effect` gains `EFFECT_PICTURE_SHAKE = 3`,
  dispatched (alongside `Flash`/`SwitchFlicker`) before the shared "delay
  must be 0" gate. Reads `arg(1)` as the interval, `arg(4)`/`arg(5)` as
  dx/dy, `arg(6)` as the shake count, across the same real contiguous
  `first..last` range every other Picture effect kind already uses.
- `WolfRPG::MapScene#set_picture_shake` stores per-picture shake state
  (`interval`/`dx`/`dy`/`count`/`counter`/`on`) in the existing
  `@pictures[number]` entry hash, the same shape `#set_picture_flicker`
  already established. Undoes any in-flight displacement first (the same
  "never start a new one on top of an old one's own leftover offset"
  reasoning), and a non-positive interval/count or an all-zero (dx, dy)
  stops it.
- `#update_picture_effects` (already ticked once per frame for
  `SwitchFlicker`/`Sprite#update`) now also toggles each active shake:
  displacing by `(dx, dy)` counts down `count` and moves away from center;
  the following tick always returns to center first, only clearing the
  state once settled back *and* `count` has reached 0 -- a picture is
  never left stuck mid-displacement even if `count` happens to hit 0 while
  still displaced.

## Consequences

- Verified by two new CRuby-level tests (the one real call's own field
  shape, and a range/nil-scene tolerance check), the CRuby harness (123
  assertions, 0 failed), `ctest -R mruby_test` (crash count held at the
  pre-existing 19-crash baseline), the testbed and interpreter soak
  checks, and the compiled binary against the real sample game.
- The native per-frame toggle/undo logic itself could not be exercised
  end-to-end the same way `SwitchFlicker`/`Flash`'s own native paths could
  not (ADR 0083/0084's own Consequences): the soak/testbed checks run
  without a real `current_scene`, so only the interpreter-level dispatch
  is exercised automatically. Reviewed by hand instead.
- Still unimplemented: every remaining Picture effect kind (Zoom,
  SwitchAutoFlash, AutoEnlarge, the auto-pattern-switch family), the
  Character and Map targets entirely, and `duration`/delay > 0 for the two
  instant one-shot kinds (`DrawPositionShift`/`ColorCorrect`). The
  "one displacement is one shake" counting assumption above stays
  unconfirmed against real data; a future pass finding a real call with a
  small, exhausting count could settle it either way.
