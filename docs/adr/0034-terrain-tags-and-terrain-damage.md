# 34. The ground you stand on

Date: 2026-08-06

## Status

Accepted

## Context

RPG2000's 地形 (terrain) table gives every lower-layer tile a row of properties:
whether a boat or a ship may cross it, which battle backdrop a fight there uses,
and — the field nothing read — how much HP the party loses for walking on it.

Two things were wrong, and only one of them was the missing feature.

### The terrain tag itself was 0 almost everywhere

`Game::ChipSet#terrain` answered **0** when the chipset carried no terrain array,
which reads as "this tile has no terrain". Counting how often that happens in the
test beds:

| | chipsets with no terrain table |
|---|---|
| Nepheshel | **96 of 100** |
| mtf-meido-action | **92 of 100** |

That is not corrupt data. RPG_RT omits the whole 162-entry array when every tile
of the chipset is terrain 1, which is the ordinary case for a chipset nobody
bothered to tag — so an absent table means *terrain 1*, not *no terrain*.
EasyRPG's `Game_Map::GetTerrainTag` says so in as many words ("RPG_RT
optimisation: When the terrain is all 1, no terrain data is stored") and returns
1.

Reading it as 0 meant that on almost every map in both games:

- Store Terrain ID stored 0, an id no database row can match;
- `Scene::Map#terrain_row_at` found no row, so boats and ships fell back to
  on-foot passability instead of the terrain's `boat_pass` / `ship_pass`;
- the terrain battle backdrop (ADR-documented, `background_name`) never
  resolved.

A census of every map in both test beds confirms it: 414,993 of Nepheshel's
lower-layer tiles read terrain 0 and 169,056 read a real tag; mtf's split 1,530
to 18,535. The overwhelming majority of the ground in both games had no terrain.

### Terrain damage was parsed and unread

The 地形 row's `damage` field, and the item row's `no_terrain_damage`
(地形ダメージ無効) that cancels it, were in the schema and used by nothing:

| | damaging terrain | gear that blocks it |
|---|---|---|
| Nepheshel | #5 ダメージ床１ (1 HP), #6 ダメージ床２ (10 HP) | スクール水着, メイド服, チャイナドレス, 邪道なる指輪 |
| mtf-meido-action | #5 Poison Swamp (1 HP), #8 Damage Floor (2 HP) | Safety Boots |

## Decision

**Read an absent terrain table as terrain 1.** `ChipSet#terrain` returns 1 for a
`nil` or empty table, and a tile id the chip index cannot reach reads the *first*
lower tile's terrain, which is what RPG_RT does for out-of-bounds coordinates,
rather than an id no row matches.

**Apply terrain damage on a step.** `Game::Party#apply_terrain_damage(amount)`
takes `amount` HP off every party member who is not already down and not wearing
gear flagged 地形ダメージ無効, and returns the members it hit.
`Game::Actor#prevents_terrain_damage?` asks the existing `equipment_flag?`
helper (ADR 0033), so any slot grants the immunity — mtf's is a pair of boots and
Nepheshel's four include a swimsuit.

`Scene::Map#note_party_step` reads it off the tile just stepped onto, through the
`terrain_row_at` helper the vehicle passability check already uses, and folds the
result into the same list the status-slip drain builds (ADR 0032). Both are the
same "your HP just fell and the map has nowhere to say so" moment, so they share
one red screen flash and one step counter — a step drains at most once from each
source, and a teleport is not a step.

The damage **cannot kill**: it goes through `change_hp` with death disallowed, so
it floors at 1 HP. This keeps terrain damage on the same footing as status slip
damage (ADR 0032): the one pair of party-damaging paths that need no game-over
re-check.

## Consequences

The terrain tag is now the tag the game meant. For 96 of Nepheshel's 100
chipsets and 92 of mtf's, every tile moves from terrain 0 (no row) to terrain 1
(a real row) — which is the change that makes the boat/ship passability rule,
the terrain battle backdrop and Store Terrain ID read the database at all on
those maps. Terrain 1 in neither game deals damage, so nothing starts hurting.

An honest limit on the second half: **neither test bed places a damaging tile on
any map.** Sweeping all 543 Nepheshel maps and all 13 mtf maps through the fixed
chipset lookup finds 0 tiles of terrains #5/#6 and #5/#8. Both authors defined
the terrain (and Nepheshel four separate garments to survive it) and then did not
use it, or used it in a map that did not ship. So this is the rare one where the
real data proves the *definition* and not the *use*: the fields are set, the
values are deliberate, and the runtime now honours them, but no walk through
either shipped game will exercise it. The chipset half is the opposite — it moves
almost every tile in both games.

Covered by `scripts/rpg2k_logic_check.rb` (an absent and an empty terrain table
both read 1; a populated one reads its own values; an unindexable tile reads the
first), by `scripts/rpg2k_scene_check.rb` (walking a damaging tile drains the
party and flashes, gear blocks it, it floors at 1 HP and skips a member already
down) and by `scripts/rpg2k_testbed_logic_check.rb`, which asserts against the
**real** tables that every one of the 96 / 92 untabled chipsets names terrain 1
across every lower block, that each game's damaging terrain wears the real party
down to 1 HP without killing it, and that each 地形ダメージ無効 item stops it
from the slot its own type names.

Left unread, and deliberately not guessed at: the terrain row's `special_flags`
/ `special_back_party` battle-formation modifiers and its `on_damage_se` sound
cue — no terrain in either test bed sets any of the three — and `damage`'s
RPG2003 sibling behaviour where a tile may kill, which needs the game-over path
this decision was written to avoid.
