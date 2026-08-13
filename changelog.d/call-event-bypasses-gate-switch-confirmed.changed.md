- **Call Event running under Auto-Start semantics and always bypassing the
  target common event's own condition-switch state are confirmed already
  correct**, no code change needed. `Game::Interpreter#do_call_event`
  splices the target's raw command list onto the *calling* interpreter's own
  call stack rather than dispatching through any trigger-aware path, so an
  Auto-Start's blocking execution mechanically carries through the whole
  call regardless of the callee's configured trigger; `Scene::Map
  #build_resolver` hands the Call Event resolver a plain `id => commands`
  hash that already discards each common event's trigger/gate-switch fields,
  so the resolver has nothing to conditionally gate on in the first place.
  Covered by a new `scripts/rpg2k_scene_check.rb` check (an Auto-Start event
  Call-Events a Parallel-Process common event whose gate switch stays off
  for the whole run; its content still executes), confirmed to fail when
  the resolver is temporarily made to honour the gate switch.
