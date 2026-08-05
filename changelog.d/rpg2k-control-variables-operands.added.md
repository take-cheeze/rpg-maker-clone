- **Control Variables** reads three more operands. A **character's screen
  position** (operand 6, selectors 4 / 5) is measured against the live camera —
  `Scene::Map#camera_position` is extracted out of `render` so the interpreter
  can ask where the view is looking — with RPG_RT's own asymmetric offsets: X
  from the tile's centre, Y from its bottom (EasyRPG's `GetScreenX` subtracts
  half a tile after adding a whole one, `GetScreenY` only adds the whole one).
  An **equipped item's id** (operand 5, selectors 10..14) reads the weapon,
  shield, armour, helmet and accessory slots. And RPG2003's **battle operand**
  (operand 8) reads a troop member's HP / SP / max HP-SP / attack / defence /
  spirit / agility during a fight. Covered by new checks in
  `scripts/rpg2k_logic_check.rb` and `scripts/rpg2k_scene_check.rb`.
