- **A Common Event's Parallel Process now survives a Transfer Player and a
  save/load, instead of always restarting from the top.** Within one map
  visit this was already correct — `Scene::Map#step_parallel` resumes the
  same `Game::Interpreter` across ticks, so a process paused by its own gate
  switch turning off genuinely freezes at that exact command — but
  `#perform_teleport` and `Scene::Map#initialize` unconditionally rebuilt
  *every* parallel process via `#build_parallels`, and `Game::State` had no
  field at all for an interpreter's position. `#build_parallels` now reuses
  the still-running interpreter (call stack, in-flight Wait countdown,
  everything) across a Transfer Player, since `Scene::Map` is the same
  instance before and after; a genuine save/load restores a coarser
  checkpoint — `Game::Interpreter#resumable_index`, persisted on the new
  `Game::State#common_event_progress` — a command index the process can
  safely resume at (skipping, not repeating, a Wait it was mid-way through).
  A Map Event's own parallel process is unaffected and still restarts fresh
  on every visit, as before. The `.lsd` export still does not carry this (LCF
  save chunks 113/114 remain undocumented opaque blobs); only the portable
  save does. See ADR 0044.
