- `Game::State.from_lsd` (via `#restore_pictures`) now reconstructs a picture
  that was already Erase Picture'd before the save it is loading from was
  written, instead of silently dropping it. The stale position/zoom/tone
  fields a genuine RPG_RT.exe always keeps for an erased-but-previously-shown
  picture (chunk 103, confirmed by an earlier cycle) were being discarded on
  load whenever the blank name looked like "never shown at all" — so a
  Continue from such a save, followed by this engine's *own* next Save, wrote
  a fully field-less placeholder where genuine RPG_RT would keep rewriting
  the identical stale bytes forever. `#key?(4)` (`current_x`, written
  unconditionally for any id ever shown) now tells "erased, remembers state"
  apart from "never touched" so the reconstructed picture is immediately
  marked erased via the same `#erase_picture` a live Erase Picture uses,
  keeping a load/save round trip stable instead of drifting further from
  genuine RPG_RT with each cycle.
