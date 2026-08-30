- **A medicine's `reverse_state_effect` flag no longer inflicts states
  instead of curing them.** A reference implementation's item-execution logic
  never reads that field for a medicine (unlike a weapon's own, RPG2003-only
  flip, or a skill's) -- the editor's checkbox does nothing for an item in
  the real engine, per that reference, not independently confirmed against
  genuine RPG_RT under wine. `state_set` is always a cure list now, regardless of the
  flag, matching the reference exactly rather than mirroring the skill
  side's mechanism on an assumption that turned out not to hold.
