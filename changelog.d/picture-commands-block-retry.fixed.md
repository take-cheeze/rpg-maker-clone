- **Interpreter:** A Show/Move/Erase Picture command reached while a message
  window or choice list is open no longer gets silently dropped forever --
  ported from a reference implementation's own picture-command handling,
  not independently confirmed against genuine RPG_RT under wine: it now
  blocks the interpreter on that exact command (and any command after it in
  the same list) and retries every subsequent frame, taking effect once the
  message closes.
