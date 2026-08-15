- **Enemy-scope attack skills** now deal SP/MP damage when their `affect_sp`
  flag is set, instead of hardcoding `mp: 0` and silently dropping it (an
  attack skill's `hp` field is now likewise gated by `affect_hp`, so an
  SP-only drain no longer also deals HP damage). Both pools draw from the
  same computed effect value, matching EasyRPG Player's
  `Game_BattleAlgorithm::Skill::vExecute`, and a killing HP hit now correctly
  skips the SP damage on that same swing. Covered by new checks in
  `scripts/rpg2k_logic_check.rb`.
