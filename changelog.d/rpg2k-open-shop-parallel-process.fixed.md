- **Open Shop issued from a Parallel Process now actually opens the shop
  screen**, instead of silently doing nothing. Confirmed against EasyRPG
  Player's source: the command runs identically for the foreground and any
  Parallel Process. This build's dispatch table for non-foreground
  interpreters had no case for it, so the request was discarded and the
  process moved on as if the command never ran.
