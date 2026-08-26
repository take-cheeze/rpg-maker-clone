- `scripts/download-killer-knights.bash` — a new RPG Maker 2003 test-bed game
  ("Killer Knights - R" / キラーナイツ－R, RPG_RT.ini's GameTitle), fetched as
  a `.zip` from the same fgamearchives mirror `download-prayforyou.bash`
  already uses. Unlike either existing 2003 bed, it ships an **empty**
  starting party (all five members join through Change Party Member events)
  and levels its five swappable companions directly via Change Level rather
  than Change EXP, so an actor's level and total EXP are not derivable from
  one another the way they happen to be everywhere else — precisely the shape
  that caught the `Party#to_h`/`#load_state` Change Class bug fixed alongside
  this download. Wired into CI next to the other RPG2000/2003 downloads;
  `rpg2k_testbed_logic_check.rb` also gained two precision fixes this game
  needed (see its own fragment) and now passes clean against it, Nepheshel and
  mtf-meido-action alike.
