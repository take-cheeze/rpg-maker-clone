- **RPG2003 battles:** A battle combo armed by the Enable Combo (1007)
  event command now clears once that fight ends, matching RPG_RT.
  Previously it stayed armed on the actor forever, multiplying hits in
  every later battle too — a boss fight scripted with a "double-strike"
  combo would leak that bonus into every subsequent random encounter.
  Covered by a new `scripts/rpg2k_logic_check.rb` check.
