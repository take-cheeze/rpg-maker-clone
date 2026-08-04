- RPG Maker 2000 main menu: the **Item** command now opens a working item screen
  (`Scene::ItemMenu`) instead of reporting "not implemented". It lists the
  party's usable medicines (database item type 6) with their held counts; picking
  a single-target item (scope 0) asks which ally to use it on, while an all-ally
  item (scope 1) heals the whole party at once. Using an item restores HP and SP
  — the flat recovery plus a percentage of the target's maximum, clamped to the
  maxima — consumes one from the bag, and refreshes the list; a use that would do
  nothing (a target already at full HP/SP) is reported and consumes nothing,
  matching RPG_RT. The decision logic lives in `Game::Party` (`field_items`,
  `item_recovery`, `item_effective?`, `use_item`) and is covered by
  `scripts/rpg2k_logic_check.rb` (the CI-run host harness); the RGSS windows are
  the UI over it. Book / seed / switch item use and the usable-occasion gate are
  left as follow-ups.
