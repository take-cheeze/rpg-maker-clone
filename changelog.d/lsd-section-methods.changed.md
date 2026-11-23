- Saving and loading an `.lsd` builds each actor, picture and vehicle record in
  a method on that object, so the save writer and reader are smaller on the
  Wio Terminal. Saves are byte-identical; `scripts/rpg2k/lsd_authoritative_check.rb`
  also round-trips a game's real saves when `RPG2K_LSD_GAME_DIR` names one.
