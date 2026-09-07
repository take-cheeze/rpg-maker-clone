# 74. WOLF RPG Editor SetVariableEx(124): the Character-state query

Date: 2026-09-07

## Status

Accepted

## Context

`SetVariableEx`(124) ("変数操作+", WolfTL's own name; the wolfrpg-map-parser
crate calls it `SetVariablePlusCommand`) is a single event command covering
four unrelated query kinds -- a character's own state (position, direction,
event id, ...), a map tile's own state, a specific `Picture`(150) number's
own state, and a grab-bag "other" category (current map id, BGM/BGS
playback state, mouse input) -- selected by a 4-value "variable type"
field. Real command dumps from the sample game (32 total, all in Common
Events) exercise three of the four: Character (29), Other (3), never
Position or PictureNumber.

The crate's own `SetVariablePlusCommand` struct reads cleanly against this
reader's own `arg(N)` framing this time (unlike `Choices`(102)/`Sound`
(140), whose own crate models needed real data to reconcile at all): its
`variable`(4B) + `options`(1B) + `assignment`(1B) header, plus a
type-specific tail that always pads to a 4-byte boundary, is exactly this
reader's own `arg(0)`/`arg(1)`/`arg(2)`/`arg(3)` for the Character and
Other variants (both confirmed empirically: Character's own tail is
`character`(4B) + `field`(4B) after 2 padding bytes that land in `arg(1)`'s
own upper 16 bits, matching the real 4-argument shape every Character-type
call carries; Other's tail is just `target`(4B) after the same 2-byte pad,
matching the real 3-argument shape). The crate's own `AssignmentOperator`
enum for this command is byte-for-byte identical to `SetVariable`(121)'s
own already-cross-confirmed one (0 `=` through 8 `abs`), packed in
`arg(1)`'s low nibble the same way; the crate's own `CharacterField` enum's
values line up with two real fields this reader can directly verify: index
2/3 (`PreciseX`/`PreciseY`) appear in the sample game's own random-
encounter Common Event querying the hero's own precise position, which is
exactly what an encounter check needs.

`SetVariableEx`'s own Character-type target argument turns out to be the
*exact same* encoding SetMoveRoute(201) already uses (`>=0` an event id,
`-1` this event, `-2` the hero, `-3..-7` a party member --
help/04ev_movesettingB.html's own convention, reused here rather than
independently re-derived) -- `#resolve_route_target` and this command's own
target resolution now share one `#resolve_character_pos` helper.

Extending `SetVariable`(121)'s own assignment-operator switch to a second
caller surfaced a real, previously-dormant bug: two of its branches used
`Integer#zero?`, a method this project's own vendored mruby fork does not
have (see ADR 0069's own discovery of the same trap for `Array#sample`/
`Hash#key`) -- untested until now because no existing fixture exercised
`SetVariable`'s own division/modulo assignment operators, but the sample
game's own `map1 ev#23`'s real `SetVariableEx` call *does* use `DivideEquals`,
so reusing the switch here would have made `ctest -R mruby_test` and the
soak check crash on real data the moment this PR landed. Fixed alongside
the extraction (`== 0` instead of `.zero?`), not filed as a follow-up.

## Decision

- `#apply_assign_op(current, computed, assign_op)` is pulled out of
  `#exec_set_variable`, fixing the `.zero?` bug in the same change, and
  reused by the new `#exec_set_variable_ex`.
- `#resolve_route_target` (SetMoveRoute's own) is rebuilt on top of a new
  shared `#resolve_character_pos(target)`, which additionally returns the
  resolved `Wolf::Event` itself (`nil` for the hero) for `SetVariableEx`'s
  own `EventId` field.
- `#exec_set_variable_ex` implements only `SET_VAR_EX_TYPE_CHARACTER`
  (variable type 1) with a 4-argument call, and only the `CharacterField`
  values this reader's own existing position tracking can answer:
  `StandardX`/`StandardY` (the runtime position tracking ADR 0069 already
  built), `PreciseX`/`PreciseY` (help/04ev_valuenext.html's own documented
  formula -- half-tile units, X the left edge, Y "the foot position minus
  one" -- applied exactly rather than approximated, since this reader
  tracks no sub-tile movement state that would make it imprecise),
  `Direction` (this codebase's own numpad convention, shared by every
  other maker here), and `EventId` (the manual's own documented "-1 when
  not a real map event" sentinel, which the hero target hits since it
  names no `Wolf::Event`). Every other `CharacterField`, and the `Position`/
  `Other`/`PictureNumber` variable types, are logged and skipped -- `Other`
  in particular has real examples (current map id, BGM/BGS playing) this
  reader chose not to wire up this pass, since neither is tracked state
  anywhere yet.

## Consequences

- The sample game's own random-encounter check (`map1 ev#37`, hero precise
  X/Y) and the message-window Common Event's own use of `DivideEquals`
  (exercised end to end by the soak check, now that the underlying bug is
  fixed) both run for real.
- `SetVariable`(121)'s own division/modulo assignment operators are no
  longer a live crash risk for any future real data that exercises them,
  independent of this command.
- Still unimplemented: `Position`/`Other`/`PictureNumber` variable types
  (Other's own two real target values -- current map id, BGM/BGS playing --
  are a natural, low-effort follow-up once that state is tracked
  somewhere), and every `CharacterField` beyond the six implemented here
  (height, screen coordinates, shadow graphic, tile tag, on-screen, active
  page, run condition, range extension, animation pattern, moving).
