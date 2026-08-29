- **An item's 使用回数 (use count) is now honoured instead of every item being
  destroyed by its first use.** A copy is spent only once it has been used as
  many times as the item's `uses` field (item field 6) says; `0` means 無制限,
  an item that is never consumed however often it is used; and the five
  equipment types are never consumed by use at all, so a 特殊効果 weapon that
  casts its skill from the Item menu is a reusable tool rather than a one-shot.
  Ported from a reference implementation, not independently confirmed against
  genuine RPG_RT under wine, including its companion rule for adding an item
  back to the bag: a copy *leaving* the bag resets the part-used tally and
  adding one never does, so selling a half-used item and buying it back
  refills its uses while topping the stack up does not. The tally survives
  Save / Continue, both in this runtime's own saves and in a genuine
  `Save<N>.lsd` (chunk 109's `item_usage`, parsed but until now unused).
  Every use site goes through one new `Game::Party#consume_item_use`: the
  field item menu, the battle Item action, medicines, skill books, seeds,
  special items, switch items and escape/teleport items alike.
