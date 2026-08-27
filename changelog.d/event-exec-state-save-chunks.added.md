- LCF save chunks 113 (`SAVE_FOREGROUND_EVENT`) and 114 (`SAVE_COMMON_EVENT`)
  now decode a genuine interpreter **call-stack snapshot** (liblcf's own
  `SaveEventExecState`/`SaveEventExecFrame`) instead of an opaque blob, and
  `Game::State#to_lsd`/`.from_lsd` wire them to `Game::Interpreter`'s real
  live state: `#call_stack_snapshot`/`#restore_call_stack` capture and
  restore the full `@call_stack` (every nested Call Event frame, each with
  its own commands/cursor), a strict superset of the older
  `#resumable_index`/`#start_at` cursor, which could not survive a save taken
  mid a nested call. A Common Event Parallel Process now resumes through this
  richer mechanism first (falling back to the old cursor for an older save),
  and a map event or Auto-Start common event mid-execution in the shared
  foreground interpreter — reachable via the event's own Open Save Menu
  command — now genuinely survives a Save/Continue too, not just within one
  session. `subcommand_path` (Show Choices branch identity) is a documented,
  deliberate no-op: this engine's own resume is cursor-based and does not
  need it. Verified by a from-scratch round trip (schema encode/decode plus a
  restored interpreter running to completion), not against a genuine
  wine-saved mid-event `.lsd`. See docs/TODO.md's cycle #191 entry.
