- **Status/Equip screens:** an actor's ATK/DEF/Int(Spirit)/AGI on the field
  Status screen, and both the current and previewed value on the Equip
  screen, now reflect any currently-active halve/double state -- matching
  RPG_RT's own `GetAtk`/`GetDef`/`GetSpi`/`GetAgi`. Previously these two
  screens showed the raw base stat, ignoring a state that persisted onto
  the map. The Equip screen's preview also no longer shows a raw, unclamped
  negative total when a heavy two-handed weapon swap forces off other
  equipment.
