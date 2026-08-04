- **Change Screen Transitions (10690).** The event command that sets how the
  screen fades in and out around teleports and battles is now handled. `Game::State`
  models the six transition slots (teleport-erase / -show, battle-start-erase /
  -show, battle-end-erase / -show) and the command sets the chosen one; they
  round-trip through the save (portable `to_h` / `load` and the LSD `SAVE_SYSTEM`
  chunks 111–116). This resolves the previously "unidentified" opcode 10690 seen
  in the RPG2000 sample games. It is modelled for save fidelity for now — the
  teleport / battle fades that would read these still use their own transition —
  the way the weather, teleport-target and system-BGM commands already are.
  Covered by a new check in `scripts/rpg2k_logic_check.rb` (the command sets the
  chosen slot, ignores an out-of-range slot, and the slots round-trip through the
  save).
