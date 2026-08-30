- **The title screen's New Game / Continue / Shutdown commands now play
  system SE too, and a grayed-out Continue is no longer silent when
  confirmed.** Follow-up to the field menu's own system-SE fix, sourced the
  same way — ported from a reference implementation, not independently
  confirmed against genuine RPG_RT under wine: each of the title screen's
  New Game/Continue/Shutdown commands play Decision right before
  acting. A Continue with no save to resume was assumed to be a pure no-op
  (the selection key "ignored"), but real RPG_RT's own title-screen handling
  plays Buzzer there instead -- the enabled check lives inside the command
  handler, not a guard that skips calling it altogether. `Scene::Title`
  matches this now: `SFX_BUZZER` on a disabled Continue confirm, `SFX_DECISION`
  on every successful command.
