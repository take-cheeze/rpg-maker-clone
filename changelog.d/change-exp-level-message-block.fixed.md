- **Change EXP / Change Level event commands:** a command with its own "show
  message" flag set is now blocked (not applied) while a message window or
  choice list is open, and retries once it closes -- matching RPG_RT's own
  Change EXP/Change Level command handling, ported from a reference
  implementation, not independently confirmed against genuine RPG_RT under
  wine, which guard the entire command (the actor's EXP/level and
  re-derived base stats included,
  not just the level-up message) behind the flag. Previously, a
  still-running Parallel Process (Message Options' "continue events") could
  apply the stat change and queue its level-up message a frame early, while
  a different event's message window still sat on screen. A command with
  the flag off is unaffected -- it never blocks.
