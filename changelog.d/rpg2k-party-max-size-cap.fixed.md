- RPG Maker 2000: the active party now caps at four members, matching
  RPG_RT (the editor never offers a fifth party slot). `Game::Party#add_actor`
  had no size check at all, so a Change Party Member "Add" past the fourth
  slot grew the party unbounded instead of silently no-op'ing. Leaving and
  rejoining once a slot frees up still works. Covered by a new
  `scripts/rpg2k_logic_check.rb` check.
