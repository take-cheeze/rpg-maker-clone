- **Battle:** an RPG2000 two-weapon (二刀流) actor's basic-Attack swings now
  both roll the merged (max hit rate / union of elemental attributes and
  weapon states / higher crit bonus) values across both equipped weapons,
  instead of each swing rolling its own weapon's data in isolation --
  matching RPG_RT's `Style_Combined`, which only splits swings by weapon
  under RPG2003's `Style_MultiHit`. Previously a low-hit or unlucky-element
  second weapon's swing was strictly worse than it should have been (or a
  strong first weapon's swing carried its bonus into a swing it shouldn't
  have), even on a genuine RPG2000 project. RPG2003 two-weapon actors are
  unaffected -- their swings still correctly resolve to one specific
  weapon's own data.
