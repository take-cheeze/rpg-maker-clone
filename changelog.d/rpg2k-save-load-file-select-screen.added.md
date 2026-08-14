- **RPG2000: a real save/load file-select screen.** The main menu's Save
  command and the title screen's Continue entry used to act on a single
  hardcoded slot; both now open a scrollable list of all 15 save slots
  (`Scene::SaveLoad`), each showing the party leader's name/level/HP, the
  party's gold and the current map, or a "No Data" placeholder for an empty
  slot. Saving can target any slot (including overwriting an occupied one);
  Continue only offers occupied slots, and is enabled as soon as *any* slot
  holds a save rather than only slot 1 (ADR 0045).
