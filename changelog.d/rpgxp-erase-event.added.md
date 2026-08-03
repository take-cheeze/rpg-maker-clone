- RPG Maker **XP** *Erase Event* (116) command. The interpreter flags the
  running event for erasure (a one-shot request drained via `take_erase_request`)
  and keeps executing the rest of the list, and `Scene::Map` removes the event —
  its marker, movement, collision, forced route and any parallel process — for
  the rest of the map visit. The removal is keyed by event id so it survives the
  `build_events` rebuild that a finishing event triggers, and erased events
  reappear only when the map is (re)loaded. Covered by a new interpreter test and
  exercised end to end by the host scene harness.
