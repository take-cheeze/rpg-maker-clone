# 77. WOLF RPG Editor Effect(290): Picture DrawPositionShift/ColorCorrect

Date: 2026-09-07

## Status

Accepted

## Context

`Effect`(290) ("エフェクト", help/04ev_effect.html) is one of the largest
remaining commands by real frequency (279 occurrences, the next-highest
after `Blank`/`LoopTimes` in the same real-data census that motivated ADR
0076): "キャラクターやピクチャ・マップに対してエフェクトをかけたり、画面の
スクロールや色調変更を行うことができます" -- a single command covering
wildly different effects across three targets (Picture/Character/Map),
each with its own list of effect kinds. The manual's own Character-target
list alone runs to roughly two dozen entries (many "Ver3.30"/"Ver3.50"
additions -- direction lock, pass-through, front-display, move speed/
frequency, animation frequency, half/full-step movement, character-chip
swapping, picture-linking...), far beyond the wolfrpg-map-parser crate's
own 4-value `CharacterEffectType` enum, which cannot even name real data's
own dominant Character-target call (effect_type 8, 66 of 279 real calls) --
the crate was evidently written against an older editor version. The
crate's own `EffectCommand` Rust enum also bundles three *other* WOLF
command codes under one type purely for its own code organization --
`MapShake`(WOLF code 280, `MapEffect`), `ScrollScreen`(281), `ChangeColor`
(151) -- none of which is `Effect`(290) at the file format level (real
data confirms this: 280/281/151 have their own vastly smaller real counts,
1/0/10, tracked as their own separate low-priority TODO items, not
attempted here).

The crate's own `Base` struct -- the variant that *is* `Effect`(290) at
the file level -- does map cleanly onto this reader's `arg(N)` framing:
7 fields (`options`, `duration`, `target`, `range`, `value1`, `value2`,
`value3`), matching every one of the 279 real calls' own 7-argument shape
exactly. `options`'s low nibble selects the target (0 Picture, 1
Character, 2 Map, byte-for-byte the crate's own `EffectTarget`), high
nibble the effect kind within it -- confirmed against real Picture-target
data, whose own effect kinds (`PictureEffectType`, 11 values) the crate
models completely and correctly, unlike the incomplete Character one.

Real data across every Picture-target call was decoded field by field:
`duration` is 0 in every real `DrawPositionShift`("描画座標シフト[最終
値]", effect_type 2, 123 of 279 real calls -- by far the single largest
combination) and `ColorCorrect`("カラー補正", effect_type 1, 14 calls)
call, confirming the manual's own "delay" feature for picture-target
effects (which reuses Picture(150)'s own still-unimplemented delay
mechanism -- see interpreter.rb's own comment on that command) is never
exercised by either; some other Picture effect kinds (`SwitchFlicker` at
least) do carry a real non-zero `duration`, so it is checked rather than
assumed. `target`/`range` name a *contiguous run* of picture numbers, and
real data confirms it is sometimes genuinely more than one (a store-
display Common Event applies one `ColorCorrect` call across six numbers,
21 through 26, at once) -- not always `target == range` the way most real
calls happen to be.

This reader already has a native rendering hook for both confirmed effect
kinds: `WolfRPG::MapScene#@pictures[number][:sprite]` (an RGSS `Sprite`,
tracked since the "Picture command" PR) exposes `x=`/`y=` directly
(`DrawPositionShift`'s own manual wording -- "単純に最終値をシフトさせる
もの", "simply shifts the final value" -- rules out needing to track the
shift as state a later Picture(150) Move would have to reapply, unlike
Picture(150)'s own transform fields) and a native `color=`/`color`
(RGSS's own additive overlay -- "ピクチャの「カラー」に加算します" per the
manual is exactly what `Sprite#color` already is, with `Color#red=` etc.
clamping to 0-255 natively, covering the manual's own documented "±200"
input range legitimately overshooting a channel already near a limit).

## Decision

- `Wolf::Interpreter#exec_effect` implements only `EFFECT_TARGET_PICTURE`
  with `EFFECT_PICTURE_DRAW_POSITION_SHIFT`/`EFFECT_PICTURE_COLOR_CORRECT`,
  and only `duration == 0` (every other target, effect kind, and a real
  non-zero duration are logged and skipped rather than silently treated
  as instant -- a visibly wrong delay is worse than an honest gap).
- `target`/`range` (both `ValueRef`-decodable like every other numeric
  slot) are applied across the full `target..range` -- every number in
  it that has an active picture; a number with none is silently skipped
  (the same tolerance `Wolf::Interpreter::Run#move_picture` already logs
  about instead, reused rather than re-derived, since Effect's own range
  calls routinely include numbers that were never shown).
- Two new `WolfRPG::MapScene` methods, `#shift_picture`/`#tint_picture`,
  are the actual rendering hook: the former adds `(dx, dy)` directly to
  the tracked sprite's `x`/`y`; the latter builds a *fresh* `RGSS::Color`
  (rather than mutating the one `Sprite#color` returns, since native and
  Ruby-side accessors are not guaranteed to share the same backing
  object) from the old color's own channels plus the given delta.

## Consequences

- The sample game's own store/menu/character-roster redraw routines
  (whose own `Effect`(290) calls this ADR's real-data survey came from)
  now shift and tint their pictures for real; verified against all 243
  real Common-Event `Effect`(290) calls replayed directly with zero
  exceptions, the soak check, `ctest -R mruby_test` (crash count held at
  the pre-existing 19-crash baseline), and the compiled binary against
  the real sample game.
- Still unimplemented, and lower-value by real frequency per the same
  census: every Picture effect kind beyond these two (Flash, Shake, Zoom,
  the blink/auto-pattern-switch family), the Character target entirely
  (66+ real calls this reader cannot even name a semantic for without
  much deeper manual research -- its own real dominant effect_type, 8,
  likely corresponds to one of the "Ver3.30+" additions the crate
  predates), the Map target (`Zoom`/`Shake`, 4 real calls), and a real
  non-zero `duration`. `MapEffect`(280)/`ScrollScreen`(281)/`ChangeColor`
  (151) remain their own separate, lower-priority TODO items.
