- **RPG2003 states:** A state RPG2003 cursed armor is actively forcing on
  an actor now survives a lethal hit (or any other state landing alongside
  it), matching RPG_RT. Previously a low-priority cursed state was wiped
  outright the instant a higher-priority state landed — most commonly
  Death itself — and stayed gone permanently, not even restorable by Full
  Recovery, until the armor was physically unequipped and re-equipped.
  Covered by a new `scripts/rpg2k_logic_check.rb` check.
