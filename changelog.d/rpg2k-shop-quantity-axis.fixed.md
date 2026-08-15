- **The shop quantity counter's tens-step now moves on the vertical axis
  instead of the horizontal one, matching real RPG_RT.** Confirmed against
  EasyRPG Player's source: `Window_ShopNumber::Update` steps the count by one
  on RIGHT/LEFT and by ten on UP/DOWN. The two axes were swapped in this
  engine, so every quantity reachable with a given sequence of key presses —
  and which key could reach a small stack's maximum in a single press —
  differed from the real game.
