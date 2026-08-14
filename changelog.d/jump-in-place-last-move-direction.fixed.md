- **A Move Route jump landing where it started now still turns the character
  to face Down internally.** `Character#jump` computes a jump's dominant-axis
  landing direction and, before this fix, only assigned it to
  `#last_move_direction` (the direction a later Move Forward continues in)
  when the jump actually moved somewhere — a net-zero "hop in place" block
  (e.g. Move Right then Move Left inside one Begin/End Jump, a common idiom)
  left it at whatever direction was recorded before the jump instead.
  EasyRPG Player's `Game_Character::Jump` (`src/game_character.cpp`) computes
  and applies that direction unconditionally, including for a same-tile jump,
  whose dominant-axis tie always resolves to Down; only the *visible* facing
  is gated behind the jump having actually moved. A Move Forward issued right
  after an in-place jump now correctly walks Down, matching real RPG_RT,
  instead of continuing in whatever direction was last recorded before the
  jump.
