- **A two-handed weapon now needs both hands.** The item row's `two_handed`
  (両手持ち) was unread, so a claymore and a shield could be worn together and
  both bonuses counted — and the flag is not rare: **35 of Nepheshel's 104
  weapons** and **14 of mtf-meido-action's 26**, more than half that game's
  arsenal. The weapon and shield slots are now mutually exclusive whenever either
  holds a two-handed weapon, and **both** slots are tested, so equipping a shield
  over a claymore drops the claymore just as the claymore drops the shield. The
  flag only counts on a weapon, as RPG_RT tests the type alongside it. The
  emptied hand returns its item to the bag rather than vanishing, since the equip
  menu swaps through the inventory. A bulk `equip` (loading a save, initial
  equipment) does not enforce it — RPG_RT stores what it stores. `double_hand`
  (二刀流 on the actor row) is the opposite rule on the same pair and is left for
  its own change. See ADR 0040.
