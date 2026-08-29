- **Interpreter:** A Battle Processing / Enemy Encounter command reached
  while a message window or choice list is open, anywhere in the scene, is
  now blocked and retried every subsequent frame instead of opening the
  fight immediately -- matching RPG_RT's own Enemy Encounter command
  handling, ported from a reference implementation, not independently
  confirmed against genuine RPG_RT under wine. A still-running parallel
  process could previously
  cut straight to the battle screen over the top of another event's open
  message window.
