- **VX Ace** the RGSS script host now boots real, unmodified VX Ace projects
  that reopen their own stock `RPG::Actor`/`Class`/`Item`/`Skill`/`Weapon`/
  `Armor`/`State`/`Enemy` script sections — which is to say, virtually every
  real VX Ace game, since the editor exposes these as ordinary editable
  script sections (its "RPG" folder) and every one of them reasserts its
  superclass on its first line, e.g. `class RPG::Actor < RPG::BaseItem`.
  Previously this raised `TypeError: superclass mismatch for RPG::Actor` and
  ended the whole run, because `mruby-rpgxp`'s XP-era schema (loaded first,
  shared by all three RGSS makers) declared these classes flat, with no
  superclass, and a class's superclass cannot change once set. The classes
  now declare the real RGSS3 `BaseItem -> UsableItem/EquipItem -> ...`
  inheritance chain from their very first (XP-side) declaration, matching
  what the stock scripts assert. Found booting a real, large freeware VX Ace
  release (not the synthetic test bed, which never reopens these the way a
  real project does) — one of the biggest remaining gaps for VX Ace support.
