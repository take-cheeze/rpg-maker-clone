- **RPG2003 battle events:** The Conditional Branch "Hero/Monster can act"
  test now actually checks whether the named battler is asleep, paralysed,
  or dead, matching RPG_RT. Previously the check invented a menu of
  sub-tests the real command never has, and its default case ("is in the
  party"/"is present") ignored the battler's status entirely — so a boss
  AI page gated on "if Hero can act..." kept treating a slept or
  paralysed party member as able to act. Covered by two new
  `scripts/rpg2k_logic_check.rb` checks.
