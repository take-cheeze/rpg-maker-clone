- `Game::Interpreter#call_stack_snapshot`'s `.lsd`-bound call-stack frames
  (cycle #191's `LCF::Schema::SAVE_EVENT_EXEC_FRAME`/`SAVE_EVENT_EXEC_STATE`,
  chunks 113/114) now carry each frame's own genuine `event_id` instead of
  mirroring the whole interpreter's single `#event_id` on every frame alike.
  `#do_call_event` (Call Event, 12330) now records, at the moment it pushes a
  frame, the concrete target map-event id `#resolve_call`/`#map_event_call`
  already resolved to fetch that frame's own commands — or `0` for a common
  event, matching liblcf's own "0 if it's common event or in other map"
  field comment (Call Event's own command format never names a different
  map, so that distinction collapses into the same `0` case here). Only the
  outermost frame still carries the interpreter's own root `#event_id`, same
  as before. This is purely save-fidelity: live "this event" resolution
  (`#character_ref`) is unchanged and still deliberately root-scoped, not
  per-frame. Covered by new `scripts/rpg2k_logic_check.rb` checks (a called
  common-event frame reads back `0`; a called map-event frame reads back its
  own target id, not the caller's; a self-call to "this event" reads back
  the same id as the caller; `#return_from_call` correctly restores the
  caller's own identity so it does not leak into a later, unrelated call).
  See docs/TODO.md's cycle #192 entry.
