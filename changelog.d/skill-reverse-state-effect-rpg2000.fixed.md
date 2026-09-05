- **A skill's `reverse_state_effect` flag now flips cure/inflict on an
  RPG2000 database too, not only RPG2003.** `Game::Battle#battle_skill_command`
  gated the flag behind `rpg2003?`, on the assumption a stock RPG2000 editor
  has no UI to set the bit and so RPG_RT would never honour it there anyway.
  Confirmed against genuine RPG_RT.exe under wine: a hand-authored RPG2000
  database enemy-scope skill with the bit set cured its target instead of
  inflicting, and the identical skill with the bit clear inflicted normally
  — RPG_RT reads and honours `reverse_state_effect` under RPG2000 regardless,
  the same way it already honours the "physical" skill-formula bit
  (`failure_message == 3`) a stock 2000 editor also cannot set. The gate is
  dropped; a database only the 2000 editor itself ever produced behaves
  identically, since it can never carry the bit set. Covered by updated
  `scripts/rpg2k_logic_check.rb` checks, confirmed to fail against the
  pre-fix code.
