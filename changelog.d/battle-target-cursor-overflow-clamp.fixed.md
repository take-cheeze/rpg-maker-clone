- **Battle screen:** the enemy-target cursor now stops at the last visible
  row instead of wrapping around once a troop has more living members than
  the four-row target window can show at once, matching RPG_RT — previously
  it wrapped modulo the full living-member count, letting the cursor reach
  and scroll past members the target list never actually scrolls to on real
  RPG_RT.
