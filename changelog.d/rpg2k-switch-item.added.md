Switch items (item type 9) can now be used from the field item menu: using one
turns on the game switch it names and consumes one from the bag.
`Game::Party#use_switch_item` consumes the item and returns the switch id, and
the item menu sets it — so events gated on that switch fire.
