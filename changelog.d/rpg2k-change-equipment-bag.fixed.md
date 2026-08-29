- **Change Equipment (event command 10450) now swaps through the party's bag,
  like the equip menu.** `Interpreter#do_change_equipment` called the bare
  `Actor#equip_item`/`#unequip` directly, so the command conjured its target
  item out of thin air and discarded whatever it replaced instead — the
  command's own comment even flagged the gap, and `Game::Party#equip_from_bag`
  (the menu's own equip path) already carried a note calling out the
  discrepancy explicitly. Confirmed against real RPG_RT by community
  デフォ戦bot trivia (independent of this codebase): the command always returns
  whatever the slot held before to the bag (both equipping and unequipping)
  and removes the newly-equipped item from it — a no-op, not a negative
  count, when the party does not hold it (adding a negative amount
  early-returns once the item's absent and the delta isn't positive). New
  `Game::Party#equip_item_from_bag` shares its bag-swap
  mechanics with `#equip_from_bag` (extracted into a private
  `#swap_equipment_through_bag`) but, unlike the menu, equips even an item the
  party does not hold — fabricating a new copy per the trivia — rather than
  refusing; `#unequip_to_bag` now also handles the command's "every slot"
  operand (5), returning each freed item to the bag in turn, the same way
  removing a full set of equipment already does it slot-by-slot.
  Covered by new `scripts/rpg2k_logic_check.rb` checks (equipping consumes a
  held copy from the bag; equipping without one still succeeds, fabricating
  rather than pulling from an empty bag; a replaced or removed item returns to
  the bag, including the "remove every slot" operand), confirmed to fail
  against the pre-fix code.
