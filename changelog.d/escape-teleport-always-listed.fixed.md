- **Field menu:** A known Escape/Teleport skill (or a special item invoking
  one) now stays listed in the field Skill/Item menu even when it is not
  castable right now -- access off, no registered target, or flying --
  matching RPG_RT, which only greys such an entry rather than hiding it.
  Choosing it while unavailable just buzzes, with no "It had no effect."
  message and no stray Decision-sound beep beforehand. Previously the whole
  entry vanished from the list outright once it stopped being castable.
  Covered by rewriting the four `scripts/rpg2k_logic_check.rb` checks that
  had asserted the old hidden-when-unavailable behavior.
