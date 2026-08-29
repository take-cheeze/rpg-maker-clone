- **Game Over screen:** a fresh Decision press now dismisses it immediately,
  matching RPG_RT's own Game Over update loop, ported from a reference
  implementation, not independently confirmed against genuine RPG_RT under
  wine (a bare trigger check with no arming/pending state at all). Previously the screen required a frame
  with neither Decision nor Cancel held before it would respond, so a
  player merely still holding Cancel -- which does nothing on this screen
  -- when it appeared had their next Decision press silently ignored until
  they let go.
