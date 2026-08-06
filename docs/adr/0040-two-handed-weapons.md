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
holds a two-handed weapon. Filling one clears the other, matching EasyRPG's
`Game_Actor::ChangeEquipment`, which does `ChangeEquipment(other_slot, 0)` after
writing the slot.

- **Both slots are tested, not just the one being filled.** Equipping a shield
  over a claymore has to drop the claymore, exactly as equipping the claymore
  drops the shield. Reading only the incoming item would let the shield win by
  going second.
- **The flag only means anything on a weapon.** RPG_RT tests
  `item->type == Type_weapon && item->two_handed`, so a shield that happens to
  carry the bit does not claim the other hand. Neither test bed has one, which is
  itself worth asserting.
- **The emptied hand goes back to the bag.** `Party#equip_from_bag` swaps through
  the inventory, so `Actor#equip_item` returns what it displaced and the caller
  returns it — otherwise equipping a claymore would destroy the shield rather
  than unequip it.
- **A bulk `equip(ids)` does not enforce it.** That path restores a saved
  loadout and sets initial equipment; RPG_RT stores what it stores, and EasyRPG
  enforces the rule only in `ChangeEquipment`. Enforcing it on load would
  silently drop a shield the save really held.

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
