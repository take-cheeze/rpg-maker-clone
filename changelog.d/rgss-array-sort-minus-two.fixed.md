- **A battle no longer ends on an `ArgumentError` when two battlers are two
  points apart.** mruby's `Array#sort` / `#sort!` use `-2` as their "the block
  did not answer with a number" sentinel *and* assign the block's own answer to
  the same variable, so a comparator that legitimately answers `-2` raises
  `comparison failed`. Ruby only specifies the *sign* of a comparator, and
  RGSS's own scripts return a difference — `Scene_Battle#make_action_orders`
  sorts the battlers by `b.current_action.speed - a.current_action.speed`, which
  every RPG Maker XP game runs at the start of every battle turn. Any two
  battlers whose speeds differed by exactly two ended the game. The comparator's
  answer is now normalised to -1/0/1, which makes the sentinel unreachable while
  keeping mruby's C sort underneath; an answer that is genuinely unusable still
  raises what it always did. Engine-wide, since it is mruby's arithmetic and the
  RPG2000 runtime sorts with difference blocks too.
