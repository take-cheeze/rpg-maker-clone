# 40. A claymore needs both hands

Date: 2026-08-06

## Status

Accepted

## Context

The item row's `two_handed` (両手持ち) marks a weapon that needs the shield hand
as well. Nothing read it, so a two-handed weapon and a shield could be worn
together and both bonuses counted.

It is not a rare flag:

| | two-handed | of weapons | shields in the game |
|---|---|---|---|
| Nepheshel | **35** | 104 | 20 |
| mtf-meido-action | **14** | 26 | 8 |

More than half of mtf's arsenal, and a third of Nepheshel's — every claymore,
great sword and hammer in either game was quietly worth a shield's defence more
than it should have been.

ADR 0033 audited the equipment combat flags and did not reach this one, because
it is not a combat modifier: it is a constraint on what may be worn at once.

## Decision

The weapon slot and the shield slot are mutually exclusive whenever **either**
holds a two-handed weapon. Filling one clears the other — ported from a
reference implementation's equipment-change routine, not independently
confirmed against genuine RPG_RT under wine, which clears the other slot
after writing the one being changed.

- **Both slots are tested, not just the one being filled.** Equipping a shield
  over a claymore has to drop the claymore, exactly as equipping the claymore
  drops the shield. Reading only the incoming item would let the shield win by
  going second.
- **The flag only means anything on a weapon.** RPG_RT tests whether the item
  is a weapon carrying the flag (ported from a reference implementation, not
  independently confirmed against genuine RPG_RT under wine), so a shield
  that happens to carry the bit does not claim the other hand. Neither test
  bed has one, which is itself worth asserting.
- **The emptied hand goes back to the bag.** `Party#equip_from_bag` swaps through
  the inventory, so `Actor#equip_item` returns what it displaced and the caller
  returns it — otherwise equipping a claymore would destroy the shield rather
  than unequip it.
- **A bulk `equip(ids)` does not enforce it.** That path restores a saved
  loadout and sets initial equipment; RPG_RT stores what it stores, and the
  reference implementation this was ported from enforces the rule only in its
  equipment-change routine, not on load. Enforcing it on load would silently
  drop a shield the save really held.

## Consequences

49 weapons across the two games claim the hand they need. No actor in either
game *starts* with a two-handed weapon and a shield, so nothing about the opening
loadouts changes; the difference is in the equip menu and in the Change Equipment
event command, which is where the pairing could be made.

Left alone: **`double_hand`** (二刀流 on the *actor* row, 4 of Nepheshel's actors
and 1 of mtf's), which turns the shield slot into a second weapon slot. It is the
same pair of slots and the opposite rule, and it wants its own change — the
menu's candidate list for slot 1 has to change with it, which this does not
touch.

Covered by `scripts/rpg2k_logic_check.rb` (a two-handed weapon empties the shield
hand and a shield knocks the two-handed weapon off, a one-handed pair lives
together, the other three slots are untouched, a shield carrying the flag does
not claim a hand, the emptied hand returns to the bag rather than vanishing, and
a bulk equip restores a saved pair as-is) and by
`scripts/rpg2k_testbed_logic_check.rb`, which equips **every** real two-handed
weapon in both games over a real shield and asserts the hand empties, and asserts
that no non-weapon in either game carries the flag.

## Addendum: `double_hand` — the opposite rule

Date: 2026-08-12

The item left alone above is now implemented, ported from a reference
implementation's equip-menu candidate-list window and its equipment-iteration
helper rather than guessed at, not independently confirmed against genuine
RPG_RT under wine, since the flag has no byte pattern of its own to read the
way a combat modifier's do — it is purely a menu-construction rule.

The reference implementation's candidate-list window retargets the whole slot
before it filters candidates — a double-hand actor's shield slot is
retargeted to the weapon slot, and its shield case admits no double-hand
exception at all — so a double-hand actor's shield slot lists weapons and
*only* weapons, not weapons alongside shields.
`Game::Party#equip_candidates(slot, actor)` does the same retargeting, and
`#equip_candidate_for?` mirrors it as a guard on `#equip_from_bag`, so the two
can never disagree about what a given slot will accept.

The harder part was not the candidate list but *placing* the result:
`Actor#equip_item`'s slot used to come from nowhere but the item's own type
(weapon → 0, always), which is exactly wrong for a second weapon that has to
land in slot 1. It now takes an optional explicit `slot`, and
`Party#equip_from_bag` passes the one its candidate list was built for — the
Change Equipment event command's own call is untouched (no slot argument, as
before), matching a reference implementation's equipment-change routine
(not independently confirmed against genuine RPG_RT under wine), which
likewise has no notion of "the second weapon slot" and always resolves a
weapon to slot 0.

Nothing about *combat* needed a change. `#attack_hit_rate`, `#weapon_crit_bonus`
and the weapon-only arm of `#equipment_flag?` (二刀流 dual-attack, 必中
ignore-evasion) already scan every equipped slot for an item whose own
*type* reads as a weapon, never slot 0 by name, so once a second weapon
occupies slot 1 they pick it up — and take the *better* of the two, mirroring
a reference implementation's own max-of-both-weapons reduction over its
equipment — for free. The stat
sum (`#equip_bonus`) was already slot-agnostic for the same reason: it adds
every equipped item's own bonus field regardless of which slot holds it.

Left alone still: whether the equip screen's slot-1 *label* changes from
"Shield" to something else for a double-hand actor. Nothing in the reference
implementation's candidate-list window (which only builds the candidate list)
settles that, and it would need its own row-label window's own source — not
checked here, so the label stays "Shield" regardless.

Covered by `scripts/rpg2k_logic_check.rb`: a double-hand actor's shield slot
offers the two held weapons and not the shield (with the ordinary weapon slot
listing the same two, and an ordinary actor still offered the shield);
equipping a second weapon from the bag lands it in slot 1, both weapons then
contributing to attack, hit rate (the better of the two) and crit bonus;
naming a shield for the shield slot directly is rejected and nothing is
spent; and a two-handed weapon equipped as the *second* weapon still empties
its neighbour, the same rule as the base ADR from the other slot.
