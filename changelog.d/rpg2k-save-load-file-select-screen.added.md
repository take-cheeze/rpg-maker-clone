- **RPG2000: a real save/load file-select screen.** The main menu's Save
  command, the title screen's Continue entry, and RPG2003's Open Save Menu /
  Open Load Menu event commands all used to act on a single hardcoded slot;
  all four now open a scrollable list of all 15 save slots (`Scene::SaveLoad`),
  each showing the party leader's name/level/HP, the party's gold and the
  current map, or a "No Data" placeholder for an empty slot. Saving can target
  any slot (including overwriting an occupied one); Continue and Open Load
  Menu only offer occupied slots, and the title screen's Continue is enabled
  as soon as *any* slot holds a save rather than only slot 1. Cancelling an
  event-triggered Open Load Menu now resumes the event instead of ending it
  outright (ADR 0045).
