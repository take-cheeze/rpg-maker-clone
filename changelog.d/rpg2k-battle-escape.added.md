- RPG Maker 2000: the party can now **flee a battle**. `Game::Battle#attempt_escape`
  rolls the RPG2000 escape chance — a formula ported from a reference
  implementation (`150 - 100 · avg_enemy_agi /
  avg_party_agi`, clamped to 0..100), not independently confirmed against
  genuine RPG_RT under wine, so a nimbler party gets away more often —
  and a preemptive first strike always succeeds. A successful escape ends the
  fight as `:escaped` (`Battle#escaped?`); a failed attempt raises the next try
  by 10 points and forfeits the party's round via the new `Battle#command_skip`,
  so every member skips its turn while the enemies still act. The battle scene's
  Escape command (cancel on the first actor's menu) now routes through this roll
  instead of guaranteeing a getaway. Covered by new `scripts/rpg2k_logic_check.rb`
  checks (agility-ratio chance and its clamps, a successful flee, the +10 on
  failure, the preemptive auto-escape, a decided-fight no-op, and command_skip).
