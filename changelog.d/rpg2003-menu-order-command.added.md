- **RPG2003's Order menu command (party reordering)** now works. Unlike Row
  (battle front/back rank) and Wait (the ATB toggle), which stay blocked on
  the unmodelled RPG2003 battle system, Order turned out to have no
  battle-system dependency at all — new `Game::Party#reorder` and
  `Scene::Order` implement it standalone, following the pick-and-place
  interaction model (not a swap or drag-drop) confirmed against EasyRPG
  Player's own `Scene_Order`. `Scene::Menu` dispatches it directly, the same
  as Item/Save, gated on the party holding more than one member.
