- **Timer:** A Timer Operation "set" sourced from a Variable is no longer
  clamped to 99:59 (5999 s) -- a prior fix's own reasoning turned out
  backwards on closer inspection: real RPG_RT's `Game_Party::SetTimer` has no
  upper bound at all, and its display genuinely garbles past 99 minutes
  rather than capping cleanly. Removed `Game::Timer::MAX_SECONDS` and the
  clamp in `#set`.
