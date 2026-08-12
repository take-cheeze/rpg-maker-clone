- RPG Maker 2000: `Game::Party#has_item?` — the "does the party have item X"
  test behind Conditional Branch's item condition and an event page's item
  appearance condition — now counts a copy currently equipped on any party
  member, not only the bag. RPG_RT's own item-possession test reads this way
  even though equipping an item removes it from the bag count `item_count`
  reports (the numeric "item possession count" operand read by Control
  Variables stays bag-only, matching RPG_RT's split between the two reads).
  Previously an event gating on "if the party has the Iron Sword" would read
  false the moment the sword was worn instead of held. Covered by new
  `scripts/rpg2k_logic_check.rb` checks.
