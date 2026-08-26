- `Game::State#to_lsd` now writes chunk 104 (hero) field 21 (liblcf's own
  `direction`, "sprite direction") as a mirror of field 22 (`facing`).
  Confirmed against a genuine kk1.12 save under wine: field 21 was present,
  holding the exact same raw value as field 22 in that capture — `#to_lsd`
  previously left it entirely absent. This codebase has no separate
  "mid-turn sprite direction vs logical facing" concept to source an
  independent value from, so the two are always written identically, the
  same write-only-mirror shape already established for chunk 104's own
  73/74 (`charset_name`/`charset_index`).
- Documented (schema.rb, no behavior change) the substantial rest of
  liblcf's `SaveMapEventBase` struct that a genuine save's hero record
  (chunk 104) carries and this codebase still doesn't model at all: `layer`,
  an in-progress custom `move_route`, `through`, several movement/animation
  frame timers, in-flight jump coordinates, and a live Flash Sprite's
  color/duration state. Left as a known gap for a future cycle.
