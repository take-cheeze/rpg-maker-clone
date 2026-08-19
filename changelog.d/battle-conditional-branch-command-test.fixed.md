- **RPG2003 battle events:** The Conditional Branch (Battle) command's "Hero
  uses the ... command" test now actually works, matching RPG_RT --
  previously it always reported false regardless of the actor's chosen
  command. Covered by a new `scripts/rpg2k_logic_check.rb` check.
