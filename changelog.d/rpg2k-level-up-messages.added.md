- **Level-up messages** for Change Level (10420) and Change EXP (10410). Both
  commands carry a "show message" flag that RPG_RT uses to announce each level an
  actor gains; the interpreter now honours it. When the flag is set and a target
  actor rises one or more levels, a message is queued per level gained and shown
  one after another before the event continues — driven through the existing
  message window, so a level-up during a cutscene pauses just like a Show Message.
  This adds a small pending-message queue on `Game::Interpreter` (drained by
  `#resume`, abandoned by `#stop`) that other multi-message commands can reuse.
  The message is a plain English line (`<Name> is now level <N>!`) for now; the
  database-term phrasing and the "learned <skill>" follow-ups RPG_RT appends are a
  later refinement. Covered by new checks in `scripts/rpg2k_logic_check.rb` (a
  two-level gain queues two messages that `#resume` drains, no message without the
  flag, and a Change EXP level-up announces) and `scripts/rpg2k_scene_check.rb`
  (the scene shows a message per level then resumes the event).
