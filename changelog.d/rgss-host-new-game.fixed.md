- **`Kernel#rand` is in the build** (`mruby-random`). A game's own scripts roll
  dice constantly — `Game_Player#make_encounter_count` does
  `rand(n) + rand(n) + 1` the moment New Game places the party — so a game died
  there with "undefined method 'rand' for Game_Player". This engine's own code
  uses seeded LCGs (its runs are diffed frame by frame against the genuine
  runtimes), which is why the gem was never needed until games ran their own
  code; `RPG::Weather` needs it too.
- **`Table#[]=` drops a write past the edge instead of raising.** RGSS ignores
  such a write without looking at the value, and a game's scripts lean on that:
  *Pray for You*'s `map_light` walks `for x in 0..(self.width)` — inclusive — and
  runs `@passages_data[x, y] |= 0x0f`, where the out-of-range read is `nil`,
  `nil | 0x0f` is `true`, and that `true` came back as the value. Converting the
  arguments before the bounds check turned it into "TypeError: true cannot be
  converted to Integer" and ended the game on New Game. In-range writes of a
  non-Integer still raise, and out-of-range reads still answer `nil` (which the
  stock scripts test for).
