- **Shop sell price (`floor(list price / 2)`), price-0 unsellability, and a
  price-0 good still being purchasable for free out of a shop's own buy list
  are confirmed already correct**, all three yado.tk-documented facts at
  once — no code change needed. `Game::Shop#sell_price` is plain Integer
  division (`price(id) / 2`, truncating toward zero same as `floor` for a
  non-negative price); `#sellable?` blocks a sale outright once
  `price(id) <= 0`, RPG2000's own way of marking a key item unsellable; and
  `#max_buy` short-circuits to the 99-item stack cap instead of dividing the
  affordable count by a zero price, so a shop stocking a price-0 good in its
  own buy list still lets the party take it for free. Already exercised by
  pre-existing, non-vacuous `scripts/rpg2k_logic_check.rb` checks.
