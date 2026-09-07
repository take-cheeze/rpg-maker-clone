# 88. WOLF RPG Editor Party(270), the two no-op Special sub-operations

Date: 2026-09-07

## Status

Accepted

## Context

`Party`(270, "パーティ画像") was flagged deliberately skipped from the very
first real-data census this session: help/04ev_party.html's own "プレイ
ヤーキャラクターたちの画像を変更します。隊列を組ませることもできます"
describes a whole feature -- up to 6 party members, each with their own
walking graphic, optionally following the hero in formation -- this reader
has never built any part of. Re-checking it after `SaveLoad`(220) (ADR
0087) turned up a smaller, real, well-confirmed slice worth implementing
after all.

`Party`(270)'s own real data is 4 calls, all through the wolfrpg-map-parser
crate's own `party_graphics_command` module (fully confirmed field-for-
field, including its own `Operation`/`SpecialOperation` sub-enums): 3 of
the 4 are `Special`(`operation` 4) calls, and both of the *distinct*
`SpecialOperation` values they use are cleanly no-ops in this reader
specifically, matching help/04ev_party.html's own wording exactly:

- `EraseAllCharacters`(1, options `20` -- `CE#80`'s own real call,
  "パーティ画像再設定"/"party image reset"): "キャラクター画像を全消去す
  る　…　パーティ全員のキャラクター画像を消去します" (erase every party
  member's own walking graphic). With no party-member sprites drawn at
  all, there is nothing to erase.
- `WarpPartyToHero`(2, options `36` -- `CE#39`'s own real calls,
  "主人公ピクセル移動切り替え"): "仲間全員を主人公の位置にワープ　…　仲
  間全員をプレイヤーキャラの位置にワープさせます" (warp every party
  member to the hero's own position). With no party members to move,
  they are already, trivially, wherever the hero is.

Both match `Blank`(0)/`Checkpoint`(99)/`WaitForMove`(202)'s own already-
established "a marker command with nothing left to do, not missing
functionality" reasoning, just discovered here instead of by a command's
own inherent one-shot nature.

`Party`(270)'s own 4th real call (`CE#80`'s own `Insert`, `options` `0x101`
-- member `1600010`, a variable-held graphics filename `1600009`) is
exactly the opposite: it genuinely needs a party roster to insert a member
into, one this reader does not have, the real "no foundation yet" case
`Remove`/`Replace`/`RemoveGraphic` (the other three top-level operations)
and every *other* `SpecialOperation` (formation-synchro, transparency,
memorize/recall, following on/off -- none seen in real data, and every one
of them would be a visibly *wrong* "did nothing" once a party actually
exists, not an honestly-missing one) share.

## Decision

- `Wolf::Interpreter#exec_party` gates on the real 1-argument shape and
  `operation == PARTY_OP_SPECIAL`(4), then no-ops for
  `PARTY_SPECIAL_ERASE_ALL`(1)/`PARTY_SPECIAL_WARP_TO_HERO`(2) specifically
  -- every other operation or `SpecialOperation` value falls through to
  `unimplemented`.

## Consequences

- Verified by two new CRuby-level tests (both real `Special` calls' own
  packed values running as genuine no-ops via the same "SetVariable
  before/after" sandwich `Checkpoint`(99)/`WaitForMove`(202) already use,
  and the real `Insert` call plus every other still-unimplemented shape
  correctly logging instead), the CRuby harness (131 assertions, 0
  failed), `ctest -R mruby_test` (crash count held at the pre-existing
  19-crash baseline), the testbed and interpreter soak checks (neither
  `CE#39` nor `CE#80` is reached by either bounded run, the same
  not-exercised-by-a-bounded-run situation ADR 0086/0087 already note for
  their own real calls), and the compiled binary against the real sample
  game.
- Still unimplemented: `Remove`/`Insert`/`Replace`/`RemoveGraphic`, and
  every `SpecialOperation` besides the two above -- all genuinely need a
  party system (roster, member sprites, formation-following movement)
  this reader has no other part of yet.
