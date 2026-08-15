- **The Simulated Attack event command's damage spread now uses RPG_RT's real
  variance formula**, instead of a coarser stand-in this codebase's own
  comment had misattributed to EasyRPG's source. Confirmed against EasyRPG
  Player's actual source: it rolls the same variance formula a normal
  attack/skill/self-destruct already uses correctly. The two formulas'
  outer bounds happen to coincide, but the old model's granularity was
  coarser by a factor that grows with the event's own Attack Power
  parameter — damage rolls visibly landed only on round multiples instead
  of the smooth, per-1 spread genuine RPG_RT produces.
