- **The shop screen now draws a status panel for the highlighted item.**
  `mruby-lcf/mrblib/schema.rb` already decoded the `possessed_items` /
  `equipped_items` database terms (Term chunk fields 92/93), but nothing in
  `mruby-rpg2k` ever referenced them. `Scene::Map`'s shop code gains
  `#draw_shop_status`, a panel beside the buy/sell list — EasyRPG's
  `Window_ShopStatus` — showing the two terms with right-aligned counts for
  whichever row the cursor sits on: the bag-only count (`Party#item_count`)
  and a new `Party#equipped_item_count`, summing how many slots across every
  party member currently hold the item — matching EasyRPG's
  `Game_Party::GetEquippedItemCount` / `Game_Actor::GetItemCount` (a plain
  slot-equality scan; equipping an item removes it from the bag, so the two
  counts move independently). `Interpreter#item_operand`'s existing
  equipped-item Control Variables mode now shares the same method instead of
  duplicating the scan inline. The panel refreshes with the list's own
  cursor and is torn down for the command menu, the quantity counter and the
  purchase/sale confirmation, none of which highlight a single item. Covered
  by a `scripts/rpg2k_logic_check.rb` check on the counting logic in
  isolation and a `scripts/rpg2k_scene_check.rb` check confirming the panel
  draws, updates and disappears correctly as the shop cursor moves.
