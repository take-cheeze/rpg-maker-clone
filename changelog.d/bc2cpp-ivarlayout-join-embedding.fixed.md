- Fixed a real, live bug in the opt-in (`RPGMAKER_BC2CPP=1`) AOT
  compiler's own whole-program ivar-embedding analysis:
  `IvarLayout.join` silently discarded an UNKNOWN-typed contribution to
  an ivar (e.g. a real `Array`/`Hash` literal assignment) whenever some
  other, earlier-processed site for the same ivar name had already
  joined in a concrete type, instead of correctly poisoning the ivar to
  permanently-dynamic the way this analysis's own documented contract
  promises. Caught building `Game::Character` (`#move_diagonal`'s own
  `@last_move_direction = [horizontal, vertical]` was silently losing to
  `#initialize`'s own earlier fixnum assignment) and confirmed to have
  already affected two previously-shipped classes: `Game::Screen` was
  wrongly embedding 11 ivars and `Game::State` 1 (`@map_id`) that can,
  on a real code path, hold a non-`Integer` value. Every embedded-field
  write already carries a runtime `mrb_integer_p` guard that raises a
  real Ruby `TypeError` rather than corrupting memory, so the practical
  impact was "a previously-working assignment now raises at runtime",
  not silent corruption -- real and worth fixing, but a materially less
  severe class of bug than the earlier `Game::Actor` embedding bug (true
  undefined behavior from a struct that was never allocated at all).
  Verified via the real generated output: `struct Game__Screen_ivars`/
  `struct Game__State_ivars` now have exactly 10 and 12 fields
  (down from 21 and 13), with every other embedded ivar on both classes
  confirmed still present and sound. See
  `docs/adr/0139-bc2cpp-lcf-file-aot-compile.md`'s own follow-up.
