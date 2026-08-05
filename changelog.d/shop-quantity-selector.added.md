- The shop now asks **how many**. Picking an item opens a quantity counter
  instead of trading one unit per confirm: UP / DOWN step by one and
  RIGHT / LEFT by ten (RPG_RT's horizontal axis, so filling a stack of 99 takes
  a few presses rather than ninety-nine), and one confirm commits the whole
  stack. `Game::Shop#max_buy` / `#max_sell` bound the counter by whichever of
  affordability, the RPG2000 99-item cap and the party's holdings runs out
  first — a price-0 good is limited only by the cap rather than dividing by
  zero — and `buy(id, n)` / `sell(id, n)` are all-or-nothing, so a count beyond
  what is allowed trades nothing rather than quietly trading fewer, and a zero
  or negative count is refused outright. An item the party has no room for
  never opens the counter, and cancelling it returns to the list having traded
  nothing. Nepheshel opens 10 shops, so this is content a real game exercises.
