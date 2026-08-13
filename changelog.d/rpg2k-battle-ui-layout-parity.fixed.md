- The RPG2000 battle screen's windows now match RPG_RT's own layout instead of
  a generic content-fitted list box. Verified against EasyRPG Player's
  `Scene_Battle_Rpg2k` / `Window_BattleStatus` sources: rows are 16px, not 14px
  (`Window_Selectable`'s `menu_item_height`); the status window is a fixed
  244x80 panel docked bottom-left showing only the **party** (RPG2000 is
  front-view — the enemy troop was never listed in a text panel, only shown
  through its battler sprites and, when targeted, the target window's name
  list); the command window is a fixed 76px panel docked bottom-right with no
  actor-name header — the acting actor is now shown by a cursor on their
  status-window row instead (`status_window->SetIndex`); and the enemy target,
  skill, item and per-action/result message panels all share RPG_RT's fixed
  80px-tall bottom rect (136px / full 320px / 244px wide respectively) rather
  than shrinking to fit their text. A list longer than four rows (an oversized
  troop or skill list) now scrolls to keep the cursor in view instead of
  overflowing the fixed panel. Covered by updated checks in
  `scripts/rpg2k_scene_check.rb`.
