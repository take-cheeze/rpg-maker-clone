- **Save screen:** Confirming a slot now pops straight back to the menu the
  same frame, with no "Game saved."/"Save failed." banner to dismiss --
  matching RPG_RT's `Scene_Save::Action`, which discards the save's own
  success/failure result and pops unconditionally either way.
