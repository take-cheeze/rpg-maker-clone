- **A medicine's `reverse_state_effect` flag no longer inflicts states
  instead of curing them.** EasyRPG's `Game_BattleAlgorithm::Item::vExecute`
  never reads that field for a medicine (unlike a weapon's own, RPG2003-only
  flip, or a skill's) -- the editor's checkbox does nothing for an item in
  the real engine. `state_set` is always a cure list now, regardless of the
  flag, matching the reference exactly rather than mirroring the skill
  side's mechanism on an assumption that turned out not to hold.
