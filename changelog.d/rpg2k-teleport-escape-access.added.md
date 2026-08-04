- The **Change Teleport Access** (11820) and **Change Escape Access** (11840)
  event commands are now handled, completing the access-flag family alongside
  Change Main Menu / Save Access. Each toggles a `Game::State` flag
  (`teleport_access` / `escape_access`) from `param0`; both default off (RPG2000
  games enable the skills once their targets are set) and round-trip through
  Save / Continue. The Teleport and Escape skills are not executed yet, so these
  gate nothing at runtime — they are modelled for save fidelity. Covered by new
  checks in `scripts/rpg2k_logic_check.rb`.
