- **Field skill menu:** A state-only skill (curing status conditions, no
  HP/SP effect) is now correctly hidden from the field menu when every
  state it touches is battle-only ("Continues after battle" unchecked),
  matching RPG_RT -- it remains a perfectly ordinary skill in battle.
  Covered by a new `scripts/rpg2k_logic_check.rb` check.
