- **Save screen:** Confirming a slot now pops straight back to the menu the
  same frame, with no "Game saved."/"Save failed." banner to dismiss --
  matching a reference implementation's own save-confirmation handling, not
  independently confirmed against genuine RPG_RT under wine, which discards
  the save's own success/failure result and pops unconditionally either way.
