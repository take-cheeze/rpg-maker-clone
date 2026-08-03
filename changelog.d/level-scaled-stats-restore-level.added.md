- The RPG2000 runtime now **scales actor base stats with level** from the
  database growth curve (chunk 31, six shorts per level, read via the new
  `LCF::Array1D#int16_values`), and **Continue restores each roster member's
  saved level and exp** before its current HP/MP -- so a resumed party comes back
  levelled and wounded with HP/MP inside correctly-scaled maxima, instead of
  keeping level-1 stats. New Game also honours a non-1 initial level.
  `rpg2k_save_load_check.rb` asserts the restored level/exp and the HP/MP bounds.
  See ADR 0015.
