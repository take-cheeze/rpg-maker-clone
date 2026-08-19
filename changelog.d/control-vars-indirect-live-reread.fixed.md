- **Events:** A batch (range) Control Variables write through an indirect
  ("pointer") operand now re-reads its target live for every variable in the
  range, matching RPG_RT -- previously the value was frozen once and
  broadcast, so a self-referencing pointer whose target fell inside the
  destination range no longer cascaded the just-written value forward.
  Covered by a new `scripts/rpg2k_logic_check.rb` check.
