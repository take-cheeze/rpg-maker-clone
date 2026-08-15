- **Return to Title Screen and Exit Game now actually fire when issued from a
  Parallel Process**, instead of silently doing nothing. Confirmed against
  EasyRPG Player's source: both commands run identically for the foreground
  and any Parallel Process. This build's dispatch table for non-foreground
  interpreters had no case for either, so a "reset the game" trap event or an
  "auto-quit once switch X turns on" idiom built entirely inside a Parallel
  Process would never actually fire.
