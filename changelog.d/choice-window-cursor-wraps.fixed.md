- **Every selectable window cursor wraps around.** Beyond the RPG2000 choice
  window, the same clamp-at-the-edge bug was duplicated across every other
  hand-rolled selection cursor in the engine: the main menu, item/skill
  target and party lists, the equip slot/candidate/actor-cycle cursors, the
  status screen's actor cycle, the Inn accept/cancel prompt, the shop list,
  every battle sub-menu (command, enemy target, skill, item, ally target),
  and the Enter Hero Name character grid. Up/Down (and Left/Right where a
  menu cycles actors) now wrap to the other end instead of stopping dead,
  matching RPG_RT. The character grid additionally wraps Left/Right within
  its own row and Up/Down by column across rows, including its ragged last
  row.
