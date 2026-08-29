- **Normal attacks and attack skills can now genuinely deal zero damage
  against a heavily-defended target, matching RPG_RT's real floor.**
  `Game::Battle.attack_damage` and `Game::Party#battle_skill_command` both
  clamped their damage formula at a minimum of 1 (`d < 1 ? 1 : d` / `dmg = 1
  if dmg < 1`); a reference implementation's normal-attack and skill-effect
  damage calculations both floor at 0 instead — ported from that source, not
  independently confirmed against genuine RPG_RT under wine — and
  this codebase's own `#enemy_autodestruct` already floored at 0 correctly,
  making the other two an internal inconsistency rather than a uniform
  design choice. Fixed both floors, and gave `Game::Battle#apply_skill_hit`
  an explicit `attack:` flag (rather than inferring attack-vs-recovery from
  the sign of `hp`, which is ambiguous exactly at 0) so a 0-damage attack
  skill still reads as an attack in the battle log instead of being
  misrouted into the recovery branch.
