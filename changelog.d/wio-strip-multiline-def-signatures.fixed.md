- `strip_wio_bc2cpp_stubs.rb` (the wio-only build step that deletes the
  interpreted-bytecode body of every method bc2cpp.rb already installs a
  real C++ override for) now supports a `def` whose own parameter list
  spans more than one physical source line -- previously an unconditional
  `raise "... def signature does not fit on one line (unbalanced parens
  on its own header line) -- not supported, refusing to guess"`, a gap
  docs/adr/0144's own "what was not done" section explicitly flagged as
  real, anticipated follow-up work ("(2) real coverage of the two
  deliberately-unsupported shapes... if the next owner's methods need
  either"), not a permanent restriction.

  Discovered as a real `wio-bc2cpp` CI failure on the *already-merged*
  PR #1732 (`Game::TextReveal#initialize`'s own 2-line signature): a
  method that could never have hit this path before -- it had an
  unconditional `#error unhandled opcode BLOCK`/`SENDB` until that PR's
  own block/RProc-fallback and self-capture rounds made it, for the
  first time ever, compile clean -- which is exactly what makes it a
  stripping candidate at all (`strip_wio_bc2cpp_stubs.rb` only ever
  considers methods `wio_registered_methods.rb`'s own real bc2cpp.rb
  capture lists as actually registered). A full sweep of the real
  `mrblib` sources for all three compiled gems against their own real
  `registered.tsv` (the exact same inputs the real wio build uses)
  turned up a second, independent real site this same PR's own
  splat-unroll round had newly unblocked: `Game::Battle#command_skill`/
  `#command_skill_all`, each a real 4-5-line keyword-argument signature
  -- reformatting either to fit the OLD one-line restriction would have
  produced a 266-291 character line, more than double the longest
  existing line in that file (139 chars) and a real readability
  regression inconsistent with this codebase's own established style, so
  fixing the tool itself (not reformatting the source) is the right fix
  here, not just the more general one.

  The fix: `first0`/`last0` (this DEFN's own deletion range) already come
  straight from the real AST parse (`node.first_lineno`/`last_lineno`),
  which spans exactly `def` through its own matching `end` regardless of
  how many physical lines the signature itself takes -- the actual
  deletion (`plan[first0] = last0`, unconditionally dropping every line
  in that range) never depended on the header's own parens being
  balanced in the first place. The only REAL hazard specific to a shared
  physical line is the same one the existing one-line-`def...end` case
  already guards against (something else sharing a line with this DEFN)
  -- checked the identical way here: the header line's own portion
  before `def` (its indentation) must be blank. No equivalent "after"
  check exists for the closing `end` line here or in the sibling
  multi-line shape that already worked before this round (signature
  closing on line 1, body starting line 2) -- a bare `end` never
  legitimately shares its own line with following code in this
  codebase's own style, and the existing "two stripped methods claim the
  same header line" check just below already catches the one adjacent-
  DEFN hazard that could otherwise slip through.

  Verified via a real end-to-end sweep: ran `wio_registered_methods.rb`
  for real (the pinned, correctly-patched host `mrbc`) against all three
  compiled gems, then `strip_wio_bc2cpp_stubs.rb` against every real
  `.rb` file in `mruby-lcf/mrblib`, `mruby-rgss/mrblib`, and
  `mruby-rpg2k/mrblib` -- zero failures (previously 2, both now fixed by
  this round alone, no source reformatting needed), every stripped
  output re-parses clean (`ruby -c`). Cross-checked the actual stripped
  diff around both fixed sites directly (not just exit codes): each
  method's own leading doc-comment is correctly preserved untouched, the
  `def`-to-`end` span is removed cleanly with no dangling/orphaned text,
  and adjacent methods are unaffected -- confirmed against a control run
  using the ORIGINAL (pre-fix) script with the two multi-line methods
  excluded from its own input, showing byte-identical behavior for every
  site this round didn't touch. `scripts/rpg2k_logic_check.rb` (1201
  checks), `scripts/rpg2k_scene_check.rb` (1062 checks) both still pass,
  unaffected (this script only runs for wio builds).
