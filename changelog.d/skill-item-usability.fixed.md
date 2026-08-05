- **Skills and items reach the battle menus at all.** Usability was decided from
  the row's `occasion_field` / `occasion_battle` flags, but RPG2000 reads those
  for **switch** skills only (ADR 0031) — the editor does not even offer the
  checkboxes for any other kind, and neither test bed writes the chunks except on
  its switch skills. Gating every skill on them left the battle skill menu
  **empty in both test beds**: 306 skills in Nepheshel and 134 in
  mtf-meido-action, none of them offered. Battle skill menus now hold 306 and
  132, and battle item menus 34 and 7 where both held nothing.
- **RPG2003 subskill categories are ordinary skills.** A 2003 game files each
  skill under a custom battle command and the category id lands in the type
  field, so testing `type == 0` rejected a skill for the sole reason that it was
  sorted into a menu — **57 of mtf-meido-action's 134 skills** (43%), including
  every one of its healing lines (Heal / Recovery / Cure / Raise are category 5).
  Its field skill menu goes from 2 skills to 12.
- **Item types 9 and 10 were swapped.** Type 9 is a special item (特殊) that
  invokes a skill and type 10 is the switch item (スイッチ); this build had the
  switch item at 9 and no notion of the special. Nepheshel's bytes settle it —
  its 14 type-9 items each name a *distinct* skill of the same name while their
  `switch_id` stays at the default, and its 41 type-10 items are the mirror
  image. So all 14 special items used to flip switch **1**, which none of them
  names, and the 41 real switch items never appeared in the bag.
- **Special items now cast their skill**, with the item taking the place of the
  SP cost — the user pays nothing and need not have learnt it. This is what
  Nepheshel's whole thrown-bomb line is (火炎玉, 爆裂玉, 氷結玉, 雷撃玉 …).
- **Switch skills now flip their switch.** That is how a Nepheshel player summons
  and dismisses a companion (skills 120–125, ファルを召還 and friends), each
  flipping the switch its common event watches — the player-facing half of the
  companion mechanic whose actor side ADR 0030 fixed.
- **Item occasion flags are read by the names the format actually uses.** The
  runtime asked every item for `occasion_field`, a field no real row carries, so
  the gate fell through to "assume usable" on all genuine data and never fired.
  A medicine is now field-usable always and battle-usable unless `occasion_field1`
  marks it field-only; a switch item reads its own `occasion_field2` /
  `occasion_battle` pair.
- **`scripts/rpg2k_testbed_logic_check.rb`** additionally asserts, against the
  real databases, that no menu comes back empty, that no skill is castable from
  neither menu, and that every special item names a real skill while every switch
  item names a switch of its own. The empty battle menus were invisible to every
  fixture check.
