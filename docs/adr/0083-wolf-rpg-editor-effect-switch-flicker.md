# 83. WOLF RPG Editor Effect(290) Picture SwitchFlicker

Date: 2026-09-07

## Status

Accepted

## Context

A fresh real-command-code census (after `LoadVariable`(221)/`SaveVariable`
(222), ADR 0082) turned up no further new top-level command worth
implementing: `220` itself and `Party`(270) both stay deliberately skipped
(ADR 0082/the `Party` TODO entry) for needing foundations this reader does
not have, and the sample game's own remaining unimplemented codes (`126`
`BanInput`, `160`/`161`/`162` transitions, `280` `MapEffect`) each have at
most a handful of real occurrences with no independent source confirming
their exact field layout. `Effect`(290)'s own *Character*-target real
calls are similarly tempting by frequency (66 real calls at `effect_type`
8 alone, almost certainly "ピクセル移動(β版)"/pixel movement per
help/04ev_effect.html's own prose menu order) but that menu order does not
match the wolfrpg-map-parser crate's own `CharacterEffectType` enum, which
only confirms codes 0-3 (Flash/Shake/SwitchFlicker/SwitchAutoFlash) and
leaves every code the real data actually needs (7, 8, 12) `Unknown` --
exactly `BanInput`(126)'s own "no independent source for the specific
encoding" situation, so the Character target stays unimplemented rather
than guessed from prose alone.

`Effect`(290)'s own *Picture* target, already partly implemented (ADR
0077's `DrawPositionShift`/`ColorCorrect`), has no such gap: the crate's
`PictureEffectType` enum confirms codes 0-10 completely, and
`SwitchFlicker`(5, "点滅A[明滅]") is next by real frequency after the two
already-implemented kinds -- 31 real calls (17 with a genuine non-zero
interval, 14 stopping one). help/04ev_effect.html documents it precisely:
"指定したRGB分の差だけ、指定フレームでカラー変更による明滅（変化前、変
化後、と交互に変化する）を繰り返します" (repeatedly alternates the
picture's color between its base state and base+RGB, every N frames), and
stops ("点滅は停止します") on either an all-zero RGB delta or a zero frame
count -- both real, and both true together in every one of the 14 real
"stop" calls.

Real data also confirms `arg(1)` (the same slot every other Picture effect
kind's existing gate treats as an unsupported *delay*, per ADR 0077) is
genuinely non-zero here (20, 3, ...) -- WOLF's own event editor UI reuses
that one field slot as a *toggle interval in frames* specifically for the
animated/looping effect kinds, unlike the two already-implemented
one-shot kinds where the same slot is a delay. `exec_effect` therefore
special-cases `SwitchFlicker` *before* the shared "delay must be 0"
gate, rather than trying to fold it into that gate.

## Decision

- `Wolf::Interpreter#exec_effect` gains `EFFECT_PICTURE_SWITCH_FLICKER =
  5`, dispatched before the existing delay-must-be-0 gate (which still
  applies, unchanged, to `DrawPositionShift`/`ColorCorrect`). It reads
  `arg(1)` as the toggle interval and `arg(4..6)` as the RGB delta, and
  calls a new `#set_picture_flicker(number, interval, r, g, b)` scene seam
  across the same `first..last` real contiguous picture-number range the
  other two kinds already use.
- `WolfRPG::MapScene#set_picture_flicker` stores per-picture flicker state
  (`interval`/`r`/`g`/`b`/`counter`/`on`) in the existing `@pictures[number]`
  entry hash, reusing `#tint_picture`'s own *additive* `Sprite#color`
  semantics rather than tracking an absolute base color: toggling "on"
  adds the delta, toggling "off" subtracts the exact same delta back out,
  so a picture with its own persistent `ColorCorrect` tint is only ever
  nudged by this effect's own contribution, never clobbered. A non-
  positive interval or all-zero delta stops any active flicker, first
  undoing it if it was mid-"on" so a new call (or a real stop call) never
  leaves a stale tint applied.
- A new `#update_picture_effects`, ticked once per frame from `#update`
  (the same shape `#update_tone` -- ChangeColor(151), ADR 0079 -- already
  established for a persistent animation, just keyed per picture number
  here instead of singular), decrements each active flicker's counter and
  toggles it when it reaches zero.

## Consequences

- Verified by three new CRuby-level tests (a real active call resolving
  the interval/RGB/range correctly, a real stop call across a real
  contiguous range, and confirming the new dispatch is not caught by the
  other two kinds' delay gate), the CRuby harness (119 assertions, 0
  failed), `ctest -R mruby_test` (crash count held at the pre-existing
  19-crash baseline), `scripts/wolf_testbed_check.rb`,
  `scripts/wolf_interpreter_check.rb`, and the compiled binary against the
  real sample game.
- `#set_picture_flicker`/`#update_picture_effects`'s own native per-frame
  toggle path could not be exercised end-to-end this pass the same way
  ChangeColor(151)'s own `Viewport#tone`/`#flash` path could not (ADR
  0079's own Consequences): the soak/testbed checks run the interpreter
  without a real `current_scene`, so only the interpreter-level dispatch
  (which scene method is called, with which resolved arguments) is
  exercised automatically. The native toggle/undo logic itself was
  reviewed by hand instead.
- Still unimplemented: every other Picture effect kind (Flash, Shake,
  Zoom, SwitchAutoFlash, AutoEnlarge, the auto-pattern-switch family), the
  Character and Map targets entirely (Character's own real "pixel
  movement" case in particular staying deliberately skipped -- see
  Context), and `duration`/delay > 0 for the two already-implemented
  one-shot kinds.
