# 100. WOLF RPG Editor: variable-reference position addressing

Date: 2026-09-08

## Status

Accepted

## Context

`vars.rb`'s own header comment already reserved (and rejected, `[:unsupported,
value]`) three ranges of the "変数呼び出し値" (variable-reference value)
addressing scheme every numeric command argument can use: `9100000+10*Y+X`
(map event Y's own position/facing), `9180000+10*Y+X` (the hero's/a
companion's own position/facing), and `9190000+X` (this map event's own),
noting plainly that they "need the map runtime this gem does not drive yet."
ADR 0099 (the party roster/formation-following work, shipped and merged
immediately before this) built exactly that runtime for the first time,
making this reservation newly answerable rather than newly discovered.

A real-data census (every command argument across the whole sample game
checked against these three ranges) found 5 real uses, all in `CE#39`'s
own "■主人公ピクセル移動切り替え" (Hero pixel-movement toggle), all
`who=0` (the hero): field 6 (facing) once, fields 7/8 (pixel offset X/Y)
twice each. `help/06valueget.html` (the vendored official manual, "変数
呼び出し値 一覧") gives the complete, unambiguous field table (`X`'s
meaning: 0/1 plain tile X/Y, 2/3 precise X/Y, 4 pixel height, 5 shadow
number, 6 numpad-convention facing, 7/8 pixel offset X/Y, 9 character-chip
image) shared identically across all three ranges.

Of that table, this reader can only actually answer fields 0/1/2/3/6
without inventing new state:

- Fields 0/1 (plain tile X/Y) and 6 (facing) map directly onto the
  `{x:, y:, direction:}` this reader already tracks for every map event
  (`#event_position`), the hero (`MapScene#hero_pos`), and now every party
  member (ADR 0099's own `#party_position`).
- Fields 2/3 (precise, half-tile-unit X/Y) reuse the *exact* formula
  `SetVariableEx`(124)'s own already-shipped `Character`/`PreciseX`/
  `PreciseY` field already established and cross-validated against
  `help/04ev_valuenext.html` (`x*2`, `y*2-1`) -- get-only there too, since
  nothing in this reader ever needed to invert it.
- Fields 4 (pixel height), 5 (shadow number), 7/8 (pixel offset X/Y) and 9
  (character-chip image) all need state this reader has never tracked for
  *any* character -- sub-tile pixel position most of all, which would mean
  building the gradual/pixel-precise movement model this reader has
  deliberately never had (every instant-scene-change command already here,
  Teleport(130) included, snaps rather than animates). These stay logged
  and rejected, the same as before -- even CE#39's own real calls (7/8 of
  its 5) fall in this camp, so this change does not fully cover its own
  motivating example, only the smaller, honestly-answerable slice of it.

## Decision

- `ValueRef.decode` now returns `[:event_position, event_id, field]`,
  `[:party_position, who, field]` (`who` 0 the hero, 1..5 a companion,
  matching `9100000+10*Y+X`'s own "Y=event id starting at 0" convention),
  and `[:this_event_position, field]` for their own three ranges, instead
  of the blanket `:unsupported` tag.
- `VarStore` gains a plain `attr_accessor :interpreter` (nil in a context
  with no real Interpreter at all -- most of this class's own test suite),
  set by `Wolf::Interpreter#initialize` to itself. `#number`/`#set_number`
  route the three new kinds through `#position_number`/
  `#set_position_number`, which resolve a live position via a new
  `Wolf::Interpreter#resolve_position_ref(kind, who)` (returning
  `[pos, writeback]` -- `pos` a live, in-place-mutable Hash for a map
  event or party member, `writeback` only set for the hero, whose own
  `#hero_pos` returns a fresh Hash every call, mirroring
  `#resolve_route_target`'s own identical hero special-case) and then
  read/write field 0/1/2/3/6 exactly as described above. Every other
  field, and any `who`/event id naming nothing real, is logged once and
  treated as 0 (read) or a no-op (write) -- never guessed at.
- Assigning to the position reference is documented as moving the
  character at its own configured speed, not instantly; this reader has
  no such gradual-movement model anywhere, so a write still snaps, the
  same corner every other instant-scene-change command here already cuts.

## Consequences

- Verified by four new CRuby-level tests in `wolf_test.rb` (the hero's own
  get/set across all four implemented fields; a companion's own get/set,
  including the "no member in that slot" no-op case; the no-Interpreter
  and unimplemented-field degradation paths; `#resolve_position_ref`
  itself against a real map event and "this event"), an updated existing
  `ValueRef.decode` test (the stale `:unsupported` expectation for these
  three ranges), the CRuby harness (168 assertions, 0 failed), the testbed
  and interpreter soak checks, and the compiled binary booted against the
  real sample game.
- **Caught two real mruby-vs-CRuby incompatibilities this pass would have
  otherwise shipped silently broken**: `Hash#invert` (an `mruby-hash-ext`
  method mruby-wolf does not declare a dependency on -- called at
  class-body load time, so it took down the *entire* `Wolf::Interpreter`
  class load under `mrbc`, not just this feature) and `Integer#zero?`
  (not implemented by any vendored gem in this build at all). Both were
  invisible to the CRuby-only harness (`ruby /tmp/wolf_unit_harness3.rb`)
  this session otherwise leans on for fast iteration, and only surfaced
  once `ctest -R mruby_test` actually ran the *compiled* mrbgem -- a
  reminder that the CRuby harness is a fast first pass, not a substitute
  for the real build, for any change touching load-time (class-body)
  code. Fixed by spelling both out plainly (a literal inverse Hash, `==
  0`) rather than adding a new gem dependency for two call sites.
- Still logged and rejected: fields 4/5/7/8/9, and the `EVENT_POSITION`/
  `THIS_EVENT_POSITION` ranges' own 0 real calls in this sample game (kept
  anyway, the same "byte layout/field table confirmed, 0 real calls" bar
  ADR 0099's own `Remove`/`Replace`/`RemoveGraphic` already cleared, since
  the field-resolution machinery is identical and free once built for the
  party range).
- Found along the way, not fixed here: `#resolve_character_pos`'s own
  comment ("-3..-7 a party member -- no party system exists yet") is now
  stale -- `SetMoveRoute`(201)/`SetVariableEx`(124)'s own party-member
  target band could plausibly resolve through the same `#party_position`
  this ADR's own `:party_position` kind already uses, now that a real
  roster exists. Left for a separate follow-up rather than folded in here.
