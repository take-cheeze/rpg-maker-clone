- The opt-in (`RPGMAKER_BC2CPP=1`) AOT compiler now also covers 4 of
  `Game::Vehicle`'s own 5 real bytecode methods (a boat/ship/airship's
  saved location), added to `mruby-rpg2k-compiled` alongside this round's
  other new target, `Game::Troop`. Neither needed any new opcode work.

  This round's own dedicated bug-fix pass closed two structural gaps in
  the whole-program MONO/POLY devirtualization registry that a prior
  round's bug-hunt had already found and confirmed live, but deliberately
  left unfixed to avoid scope creep: `class << self ... end` singleton-
  class bodies were completely invisible to the registry (8 real
  instances found in `mruby-rgss`, including `RGSS.asset_archive` and over
  twenty of `RGSS::Audio`'s own methods, none of them registered at all
  before this fix), and an empty `class`/`module` body (`class Timeout <
  StandardError; end`) could leak stale ownership tracking into a later,
  unrelated construct reusing the same register -- confirmed live:
  `RGSS.asset_archive`/`asset_archive=` registered under owner
  `RGSS::Timeout` instead of `RGSS`. Both closed by one mechanism: `SCLASS`
  now gets the same real recursion `CLASS`/`MODULE` already have, and the
  matching `EXEC` must now land on the exact next instruction, closing the
  leak structurally. Verified via a full before/after registry diff (every
  change is additive or a correction, zero already-correct entries moved)
  and a real build (`RGSS::Sprite`'s own entry-point count unchanged).
  Also documents a further, related, explicitly out-of-scope finding for a
  future round: an unfused singleton-method shape for very large class
  bodies has the same blind spot, confirmed real but not currently
  exploitable. See `docs/adr/0139-bc2cpp-lcf-file-aot-compile.md`'s own
  follow-up.
