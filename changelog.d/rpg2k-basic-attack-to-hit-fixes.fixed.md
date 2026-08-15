- **A basic Attack's to-hit chance is now correct in two ways it wasn't
  before.** A "do nothing"-restricted target (asleep / paralysed) now always
  gets hit, instead of still rolling the ordinary hit-rate/agility math — a
  restricted target was RPG_RT's one guaranteed landing, and this codebase
  never implemented that rule at all. Separately, a state's `reduce_hit_ratio`
  (Blind and friends) now scales the attacker's base hit rate *before* the
  agility adjustment runs, not the finished, agility-adjusted percentage
  afterward — the two orders disagree whenever attacker and target have
  unequal agility, since the agility term is not linear in its input. Both
  confirmed against EasyRPG Player's `Algo::CalcNormalAttackToHit`.
