- **Open Save Menu, Open Main Menu and Open Load Menu now actually open their
  screen when issued from a Parallel Process**, instead of silently doing
  nothing. Ported from a reference implementation, not independently
  confirmed against genuine RPG_RT under wine: all three commands run
  identically for the foreground and any Parallel Process. This build's
  dispatch table for non-foreground interpreters had no case for any of them,
  so an "auto-save trap" idiom or a custom pause-menu hotkey built entirely
  inside a Parallel Process would never actually open anything.
