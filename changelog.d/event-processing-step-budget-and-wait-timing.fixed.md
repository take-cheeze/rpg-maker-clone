- The event-command interpreter's per-frame step budget (`Game::Interpreter::MAX_STEPS`)
  is now 10000, matching RPG_RT's own documented ceiling, instead of
  1,000,000 -- a heavy or runaway event loop now visibly spreads across
  several frames the way it does in RPG_RT, rather than finishing effectively
  instantly. Within that budget, a Loop iteration, a Call Event round trip,
  a Conditional Branch evaluation and the End Branch it falls through to now
  cost more than one step each, per RPG_RT's measured event-command timings
  (`el-flamen`'s `rpgTkool2000/commandSpec`). Call Event nesting
  (`MAX_CALL_DEPTH`) is now bounded at 1000 levels rather than 100, matching
  the documented real limit before RPG_RT aborts with an "invalid event call"
  error.
- `Wait 0.0 sec` now costs exactly one frame (1/60s) as documented
  (`el-flamen`'s `rpgTkool2000/eventProcess`), for both the foreground event
  and background parallel processes -- previously the scene's per-frame drive
  loop spent an extra frame resuming a finished wait before it would run the
  next command, so a `Wait 0.0` command cost two frames in the foreground and
  three in a parallel process instead of one and two respectively. A parallel
  process's own free one-frame gap between laps is unaffected, so stacking an
  explicit `Wait 0.0` on top of it now gives the documented 2-frame (1/30s)
  total gap. Covered by new checks in `scripts/rpg2k_logic_check.rb` and
  `scripts/rpg2k_scene_check.rb`.
