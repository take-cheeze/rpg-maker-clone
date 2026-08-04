- The **Open Shop** (10720) event command is now a playable subsystem. It opens
  a shop over the goods listed in the command (a buy+sell, buy-only or sell-only
  screen per its mode): buying deducts the database price and adds the item,
  selling returns half the price and removes it, with the party's 99-item and
  gold caps enforced. A new `Game::Shop` owns the transaction rules
  (affordability, stock, sellability) and tracks whether anything was traded,
  which — exactly like the inn — selects the command's optional `[Transaction]` /
  `[No Transaction]` handler branches (markers 20720 / 20721, closed by 20722).
  `Game::Interpreter` records the request and suspends on a `:shop` wait;
  `Scene::Map` drives the buy / sell menus and resumes it on leave. Buying and
  selling are one unit per confirm for now (the quantity selector is a later
  refinement). Covered by new checks in `scripts/rpg2k_logic_check.rb` and
  `scripts/rpg2k_scene_check.rb`.
