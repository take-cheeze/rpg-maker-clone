- **Save & Continue:** status panels now display `max(current, computed_max)`
  for HP/MP, so a resumed save whose saved HP/MP exceeds this engine's
  recomputed growth curve (a genuine RPG_RT save under wine showed 600/600
  where the curve computes 245/254) reads `600/600` like RPG_RT instead of
  `600/<smaller max>`. `Game::Actor#display_max_hp` / `#display_max_mp` (and
  the `Game::Battle::Combatant` twins) provide the ceiling; the genuine
  recomputed maximum still drives all damage / heal / recalc clamping. The
  underlying growth-curve discrepancy is left as a separate research question.
  Covered by a new `scripts/rpg2k_logic_check.rb` check.
