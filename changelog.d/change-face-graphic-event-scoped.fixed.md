- **Change Face Graphic now auto-clears when the event that set it finishes**,
  instead of staying selected forever like Message Options does. yado.tk
  documents the two as having different lifetimes: a face applies to every
  message the rest of its own event shows (Call Event nesting included), but
  is auto-cleared the instant that event's command list genuinely runs out —
  not just by an explicit empty Change Face Graphic. `Game::Interpreter`
  modelled the face as `Game::MessageConfig` state shared and persisted the
  same sticky way as Message Options, with nothing anywhere clearing it at
  event end. `#do_change_face` now marks the interpreter as owning the shared
  face state whenever it sets a real (non-empty) face, and `#update` drops
  that claim — clearing `message_config`'s face — the moment its own command
  list finishes normally; an unrelated interpreter finishing elsewhere never
  touches a face it didn't set. Message Options are untouched: nothing resets
  them, matching RPG_RT. Covered by three new `scripts/rpg2k_logic_check.rb`
  checks (the face persists across multiple messages within one event but
  clears once it ends, while Message Options set in the same event stay
  sticky; a face set inside a Call Event survives back into the caller and
  only clears once the whole call finishes), confirmed to fail against the
  pre-fix code before the fix.
