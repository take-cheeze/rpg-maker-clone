- **RPG2003 battles:** A skill that shifts attribute-defence ranks (e.g. a
  "Ward Fire"-style buff, or a curse that weakens resistance) now rolls its
  own independent hit chance for each targeted attribute, matching RPG_RT.
  Previously the shift landed on every listed attribute unconditionally,
  with no accuracy roll at all, so a skill tagged to affect several
  attributes at once always shifted all of them together instead of
  potentially hitting some and missing others like its other effects
  already do. Covered by a new `scripts/rpg2k_logic_check.rb` check.
