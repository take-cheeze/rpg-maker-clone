- RPG Maker **XP** events now handle **Set Event Location** (202) and **Change
  Transparent Flag** (208). 202 snaps the player or a map event onto a tile
  (direct, from a pair of variables, or exchanging places with another event)
  and optionally turns it, the way RMXP's `Game_Character#moveto` does — no
  walking, no passability test — carrying the leader's mid-step bookkeeping with
  it so it cannot glide back. 208 stops the party leader being drawn, which is
  how a cutscene hands the hero's tile to an event that looks like him; it is
  part of the saved state. Between them 86 uses in Pray for You.
