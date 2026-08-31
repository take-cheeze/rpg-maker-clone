- **A confirm-key press facing a Player-Touch/Event-Touch, same-layer event
  only actually answered by decision key on a lucky frame — one where a
  direction key toward it was not also held at the exact same instant.**
  Found immediately after the previous fix, testing Nepheshel map 23 event
  29's own flagless "HiddenDoor": pressing confirm while still leaning on the
  direction key (the natural way to walk up to a wall and then search it)
  made the door open only rarely, even though the underlying Move Event
  queueing was by then already fixed. `Scene::Map#update` runs
  `#step_movement` (which processes a held direction key, including bumping
  into a same-layer touch event) before `#try_action_trigger` (the confirm
  key) every frame. `#step_movement`'s own touch-bump branch called
  `#start_event(touched)` — the default `by_decision_key: false` overload —
  unconditionally on any touch-triggered same-layer event, and that started
  interpreter then made `#try_action_trigger`'s own `#event_busy?` guard bail
  out for the rest of that same frame, before it ever got a chance to
  discover the identical event on the tile the player is now facing and
  start it correctly with `by_decision_key: true`. A page whose script gates
  on "the decision key started this event" (Conditional Branch type 8, what
  Nepheshel's HiddenDoor and the pre-existing `scripts/rpg2k_scene_check.rb`
  check for it both exercise) only ever saw the wrong flag on such a frame,
  and starting the event this way at all was pure waste — its script ran
  once for nothing every single frame the direction key happened to be held
  down at the moment confirm was pressed.
  Fixed by skipping `#start_event(touched)` in `#step_movement`'s touch-bump
  branch specifically when the confirm key was also just pressed this frame
  *and* the same tile would independently answer the action button
  (`#action_touch_trigger?`) — `#try_action_trigger`, called later the same
  frame, already re-discovers the identical event through the freshly
  updated `@state.direction` (set earlier in `#step_movement`, before the
  touch-bump branch runs) and starts it correctly, so skipping the bump here
  costs nothing but its wrong flag. An ordinary Player/Event-Touch event that
  is not action-answerable (not same-layer, or the coincidence of an
  unrelated confirm press bumping into an NPC that never reads this
  condition type) is untouched, since `#action_touch_trigger?` is what gates
  the change. Covered by a new `scripts/rpg2k_scene_check.rb` check (holding
  the direction key toward a Player-Touch/same-layer event while pressing
  confirm on the same frame still runs its decision-key branch, and the
  party still does not step onto the event), confirmed to fail against the
  pre-fix code (`switches[9]` stays unset) before the fix.
