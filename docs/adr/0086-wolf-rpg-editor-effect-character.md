# 86. WOLF RPG Editor Effect(290) Character Flash/Shake

Date: 2026-09-07

## Status

Accepted

## Context

A fresh look at `Effect`(290)'s own remaining real-frequency gaps after
`SwitchFlicker`/`Flash`/`Shake` (ADR 0083-0085) found every remaining
Picture effect kind at 1-2 real calls, and the Map target's own `Zoom`
(4 calls, tied with Picture `Shake`) needing a whole-camera transform this
reader's single map `@viewport` has no native support for -- confirmed by
checking `mruby-rgss/src/lib.cxx`'s own `Viewport` method table directly
(`ox`/`oy`/`rect`/`color`/`tone`/`flash`/`update`, no zoom of any kind),
ruling it out as a Ruby-only addition the way every other Effect(290)
increment this session has been.

The Character target's own real calls are dominated by `effect_type` 7/8/
12 (66+ of them, almost certainly "ピクセル移動(β版)"/pixel movement by
help/04ev_effect.html's own prose menu order), but the wolfrpg-map-parser
crate's own `CharacterEffectType` only confirms codes 0-3 (Flash/Shake/
SwitchFlicker/SwitchAutoFlash), `Unknown` beyond -- and that prose order
does not match the crate's own 0-3 numbering (the crate assigns Flash=0,
but the manual's own menu lists pixel movement *before* Flash), so this
reader cannot confirm what 7/8/12 mean and continues to leave them
unimplemented, `BanInput`(126)'s own "no independent source for the exact
encoding" situation.

What the crate *does* confirm for Character -- `Flash`(0) and `Shake`(1),
byte-for-byte the same codes as their Picture-target namesakes -- has only
2 real calls total (both a "this event" target), but reuses this reader's
own already-built `#flash_picture`/`#set_picture_shake` mechanics almost
directly, just resolved to a character's own live sprite instead of a
picture number. Real frequency alone would rank this behind `Zoom`, but
`Zoom`'s architectural cost (see above) makes `Flash`/`Shake` the better-
scoped next step despite the lower count -- the same reasoning `Shake`
itself was picked over `Zoom` for in ADR 0085.

`arg(2)` (Picture's own "target" field, a picture-number range start)
reuses, byte-for-byte, `SetMoveRoute`(201)/`SetVariableEx`(124)'s own
already-cross-confirmed target convention instead (`>=0` an event id,
`-1` this event, `-2` the hero, `-3..-7` a party member, no party system).
`arg(3)` ("range" for Picture) is always 0 in real data -- there is only
ever one character per call, unlike Picture's own contiguous range -- so
it is decoded but otherwise unused.

## Decision

- `Wolf::Interpreter#exec_effect` now dispatches by `target_sel` first
  (`exec_effect_picture`/`exec_effect_character`), rather than gating
  everything but Picture as unimplemented up front.
- `exec_effect_character` resolves `arg(2)` via the existing
  `#resolve_character_pos` (plus the same explicit `target ==
  ROUTE_TARGET_HERO` check `#resolve_route_target` already makes, since
  `#resolve_character_pos` alone cannot distinguish "the hero" from "an
  unsupported party member" -- both return a nil event) to a stable
  `sprite_key` (`:hero`, or an event's own id), unimplemented for anything
  that does not resolve (a dangling event id, "this event" outside a
  running map event, or a party member).
- `WolfRPG::MapScene#flash_character`/`#shake_character` resolve
  `sprite_key` to the hero's or an event's own live sprite (a new
  `#character_sprite`, mirroring `@pictures[number]`'s own lookup but
  against `@hero_sprite`/`@event_sprites`) and apply the exact same logic
  `#flash_picture`/`#set_picture_shake` already do, just against that
  sprite directly instead of a `@pictures` entry. Shake's own persistent
  state lives in a new `@character_shakes` Hash (keyed by `sprite_key`,
  since a character has no `@pictures`-style entry hash of its own to hang
  state off of), ticked by a new `#update_character_effects` -- the
  Character-target counterpart to `#update_picture_effects`, which also
  now calls `#update` on `@hero_sprite` and every live `@event_sprites`
  value each frame, the same native-`Sprite#flash`-needs-a-periodic-
  `#update`-call fact ADR 0084 already found and fixed for pictures and
  (one level up) `@viewport`.

## Consequences

- Verified by three new CRuby-level tests (the one real Flash call's own
  shape via "this event", Shake resolving both an explicit event id and
  the hero, and the existing "skips" test extended to cover an unconfirmed
  Character effect type, an unresolvable party target, and the still-fully-
  unimplemented Map target), the CRuby harness (125 assertions, 0 failed),
  `ctest -R mruby_test` (crash count held at the pre-existing 19-crash
  baseline), the testbed and interpreter soak checks, and the compiled
  binary against the real sample game.
- Unlike every other Effect(290) increment this session, the soak check
  (which runs every real Common Event and map event for up to 600 frames)
  never actually exercises either real Character Flash/Shake call: CE#39
  ("主人公ピクセル移動切り替え") is not an auto/parallel Common Event and
  nothing in the bounded, input-less soak run ever triggers it, so no
  "Effect(290)" warning of any kind (implemented or not) appears in its
  own output. The interpreter-level dispatch (target resolution, argument
  decoding, which scene method gets called) is verified directly by the
  three new tests instead; the native per-character sprite/flash/shake
  path itself was reviewed by hand, the same limitation ADR 0083-0085
  already note for their own native paths.
- Still unimplemented: the Character target's own dominant real usage
  (`effect_type` 7/8/12, no independent source), the Map target entirely
  (needs native `Viewport` zoom support this reader does not have), and
  every remaining Picture effect kind (Zoom, SwitchAutoFlash, AutoEnlarge,
  the auto-pattern-switch family).
