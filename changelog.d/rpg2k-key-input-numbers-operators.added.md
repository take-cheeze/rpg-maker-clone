- **Key Input Processing** (11610) now decodes RPG2003's own Numbers /
  Operators parameter layout (`db.rpg2003?`-gated, since it reuses the same
  param5/param6 slots RPG2000 1.50+ uses for Shift and the arrows) into the
  request's accepted-key set, instead of silently ignoring those params. The
  two flags are decoded but not yet actionable — `RGSS::Input` models a fixed
  console/keyboard button set with no numeric-keypad or operator keys to
  sample, so a Numbers/Operators-only request can never resolve; other
  accepted keys in the same request (Decision, Cancel, arrows, Shift) are
  unaffected. Mouse input (Maniac) remains fully out of scope. Covered by new
  checks in `scripts/rpg2k_logic_check.rb` and `scripts/rpg2k_scene_check.rb`.
