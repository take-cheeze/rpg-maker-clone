- **The shop screen now talks, in the database's own words.** RPG2000 gives
  every shop one of three shopkeeper "voices" (`Open Shop`'s own type
  parameter selects `shop_*1` / `_2` / `_3`), and none of the eleven term
  categories that voice speaks through were ever read: the command menu's
  Buy / Sell / Leave rows were hardcoded English, and the shop never greeted
  the player, prompted them on the buy / sell / quantity screens, or spoke at
  all beyond the mechanical lists. `Scene::Map#shop_terms` (mirroring the
  existing `#inn_terms`) resolves the right voice with an English fallback
  for a blank field, and `#shop_header` draws one extra line above whichever
  screen is up: the shopkeeper's greeting on first opening the command menu,
  switching to `shop_regreeting` once the player has gone into Buy or Sell at
  all this visit (EasyRPG's `Window_Shop` keys this off a per-visit flag, not
  a persisted "have I shopped here before"), and `shop_buy_select` /
  `shop_sell_select` / `shop_buy_number` / `shop_sell_number` on their own
  screens. The command row labels (`shop_buy` / `shop_sell` / `shop_leave`)
  replace the hardcoded English outright, the same way EasyRPG's
  `Window_Shop::Refresh` uses them as the row text directly rather than
  combining them with anything.
  Left composed: `shop_purchased` / `shop_sold`, the confirmation line after a
  transaction completes — showing it needs a pause-for-keypress step this
  screen's quantity-counter-then-back-to-list flow doesn't have yet, so it is
  left for its own change rather than guessed at. Covered by a new check in
  `scripts/rpg2k_scene_check.rb` walking a real shop from its first greeting
  through Buy, the quantity prompt, and back to the command menu to see the
  regreeting.
