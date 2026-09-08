# 99. WOLF RPG Editor: a basic party roster and formation-following

Date: 2026-09-08

## Status

Accepted

## Context

ADR 0088 left `Party`(270, "パーティ画像") mostly unimplemented for want of
any party system at all: only the two `Special` sub-operations that are
trivial no-ops on an empty roster (`EraseAllCharacters`/`WarpPartyToHero`)
were handled; `Remove`/`Insert`/`Replace`/`RemoveGraphic` and every other
`Special` sub-operation all genuinely need a roster, member positions, and
formation-following movement this reader had no other part of.

Two independent sources ground this without guessing:

- `help/04ev_party.html` (the vendored official manual) is plain and
  unambiguous about every operation's semantics: a party is the hero plus
  up to 5 "仲間" (companions); `Remove`/`Insert`/`Replace` each name a
  1-based "[指定]人目" (Nth person) among the companions (never the hero);
  `RemoveGraphic` matches by image instead of position; `Special`'s own 11
  sub-operations are individually described, including the default
  following behavior in exact, implementable terms: "X番目の仲間の動きは、
  主人公のY回前の移動方向を再現する" (the Nth companion's movement
  reproduces the hero's own movement direction from Y moves ago).
- The `wolfrpg-map-parser` crate's own `party_graphics_command` module
  (already used, field-for-field, in ADR 0088) confirms the exact byte
  layout structurally: `options`'s low nibble (`Operation`), next nibble
  (`SpecialOperation`), and bit 8 (`graphics_is_variable`); a `member`
  field present only for `Remove`/`Insert`/`Replace`; a `graphics` field
  (a literal string or, if the bit is set, a variable-held one -- the same
  convention Picture(150)'s own file argument already uses) present for
  `Insert`/`Replace`/`RemoveGraphic`. This reader's own real command dump
  confirms the concrete shape: `CE#80`'s own real `Insert` call is
  `[257, 1600010, 1600009]` -- `options` 0x101 decodes to
  `Insert`+`graphics_is_variable`, with both `member` and `graphics`
  themselves variable-held (this-common-event-self addresses, so their
  actual runtime values were never resolved statically by inspection
  alone).

This is the same "byte layout confirmed independently, semantics confirmed
by the manual" bar `StringCondition`(111)/`BreakEvent`(172) already cleared
with few or 0 real calls of their own -- `Remove`/`Replace`/`RemoveGraphic`/
most `Special` sub-operations have 0 real calls in this sample game, but
nothing about their own meaning is in dispute the way `Teleport`(130)'s
target `-1` turned out to be (that attempt, made and reverted earlier this
same session, ran into real cross-map ambiguity no source resolved --
nothing comparable exists here).

`StartHeroPartySynchro`/`CancelHeroPartySynchro` (a *different* following
mode: "現在の位置関係を保ったまま移動させる", preserving each member's own
fixed relative offset instead of trailing through position history),
`MakePartyTransparent`/`CancelPartyTransparency`, and
`SavePartyMembers`/`LoadPartyMembers` all still have 0 real calls *and*
would each need a genuinely new rendering/snapshot concept with no real
shape to confirm a design against -- these stay unimplemented, the same
"would be a visibly wrong 'did nothing' once a party exists" line ADR 0088
already drew for the whole feature.

## Decision

- `Wolf::Interpreter` gains a roster: `@party`, a fixed `PARTY_MAX_MEMBERS`
  (5) slots, each `nil` (no one there) or `{graphic:}` (`graphic` itself
  nilable -- "空白キャラ", a member present with no walking graphic), and
  `@party_positions`, the parallel per-slot runtime `{x:, y:, direction:}`.
  `#party_members`/`#party_position(i)` are the read-only view
  `WolfRPG::MapScene` renders from.
- `exec_party` now dispatches every operation for real:
  `Remove`/`Insert`/`Replace` resolve `member` (`#party_slot_index`, 1..5,
  logged as unimplemented outside that range) and shift the roster
  array accordingly (`Insert` shifts later slots back, dropping whatever
  fell past slot 5; `Remove` shifts later slots forward); `RemoveGraphic`
  clears every slot whose own `graphic` matches, wherever it is;
  `Special`'s `PushCharactersToFront` compacts gaps forward;
  `EraseAllCharacters`/`WarpPartyToHero` now act on the real roster (clear
  it outright; reset every occupied slot's own position to the hero's
  current one) instead of relying on it being trivially empty;
  `TurnOnPartyFollowing`/`TurnOffPartyFollowing` toggle a new
  `@party_following` flag, `true` by default, matching the manual's own
  documented default state.
- Formation-following movement (`#party_advance`, called from
  `WolfRPG::MapScene#move_hero` immediately after every real hero step,
  passing the position just left) is a plain one-step follow-the-leader
  chain: each occupied slot receives the position the slot ahead of it (or
  the hero, for slot 0) held *before* this step. By induction this
  reproduces the manual's own "Y moves ago" wording exactly, with no
  separate history-depth buffer needed; an empty slot does not have a
  position of its own but does not interrupt the chain either -- the
  value passes through to the next occupied slot, so only the explicit
  `PushCharactersToFront` operation actually closes a gap.
- `WolfRPG::MapScene` draws each occupied slot as a small colour block
  (`PARTY_MEMBER`, distinct from `HERO`/`EVENT_MARKER`) -- the same
  fidelity level the hero itself is still at; ADR 0093's real-ChipSet work
  only ever covered map tiles, not character sprites, so party members do
  not regress anything already real.

## Consequences

- Verified by thirteen new CRuby-level tests in `wolf_test.rb` (Insert
  seeding a new companion at the hero's own position, both the real
  variable-held shape and a literal-string one; Remove/Replace/
  RemoveGraphic/PushCharactersToFront each exercised directly;
  WarpPartyToHero/EraseAllCharacters against a real, non-empty roster, not
  just the already-covered empty case; `#party_advance`'s own chaining
  proven across three consecutive hero steps; TurnOff/TurnOnPartyFollowing
  actually gating `#party_advance`; the out-of-range-member/still-
  unimplemented-Special/wrong-argument-count cases), the CRuby harness
  (164 assertions, 0 failed), `ctest -R mruby_test` (0 KO / 0 crashes,
  unchanged), the testbed and interpreter soak checks, and the compiled
  binary booted against the real sample game (CE#80/CE#39, the two real
  Party callers, are not reached within the soak/boot window's own bounded
  run, the same "not exercised by a bounded run" situation already true of
  ADR 0088's own real calls -- this is a pre-existing property of *when*
  those Common Events run, not something this change affects).
- Still unimplemented, deliberately: `StartHeroPartySynchro`/
  `CancelHeroPartySynchro`, `MakePartyTransparent`/
  `CancelPartyTransparency`, `SavePartyMembers`/`LoadPartyMembers` -- 0
  real calls, each needing a new rendering/snapshot concept with nothing
  real to confirm a design against.
- Party member graphics are never actually loaded/rendered as real
  character sheets -- the hero itself is still a colour block too (ADR
  0064's own still-open follow-up), so this does not newly fall behind
  anything already real.
- `vars.rb`'s own `ValueRef` table already reserves (and explicitly
  rejects, "needs the map runtime this gem does not drive yet")
  `9180000..9189999` for getting/setting a party member's own position
  through the ordinary variable-reference mechanism, the same way
  `9100000..9179999` does for map events. That runtime now exists for the
  first time; wiring that addressing range up to read/write
  `@party_positions` is a natural next step, not attempted here to keep
  this change to the `Party`(270) command itself.
- `member`'s own 1-based, companion-only indexing (slot 0 = "1人目") is the
  plain reading of the manual's own wording, not independently confirmed
  by real data (`CE#80`'s own `member` value was never resolved
  statically) -- flagged here the same way this session flags any
  reading that rests on the clearest available source rather than a
  compiled reference.
