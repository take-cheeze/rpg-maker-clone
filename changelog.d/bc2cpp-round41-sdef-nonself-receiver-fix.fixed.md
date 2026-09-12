- A dedicated adversarial correctness sweep of four `bc2cpp.rb`
  mechanisms added since round 34's own last whole-program sweep
  (`DIRECT_CONSTRUCT_TARGETS`, `NATIVE_ARG_TARGETS`, `.singleton` owner
  support, and `strip_wio_bc2cpp_stubs.rb`'s companion-statement
  stripping) found and fixed one real, latent soundness bug in the
  whole-program MONO/POLY registry: the `SDEF` opcode case (`def self.foo`
  fused into one opcode) hardcoded its own owner as the enclosing
  namespace's own singleton, on the unstated assumption that `SDEF`'s own
  receiver is always `self`. It isn't, structurally — `codegen_sdef`
  (`mrbgems/mruby-compiler/core/codegen.c`) evaluates `SDEF`'s own
  receiver as an arbitrary expression, and the real VM (`src/vm.c`'s
  `OP_SDEF`) takes the singleton class of whatever value that register
  holds at runtime, exactly like `OP_SCLASS` does — a real `def
  SomeConst.foo` that fuses to `SDEF` (reachable exactly like today's own
  `def self.foo` targets) would have been silently registered under the
  WRONG owner. The unfused sibling shape (`TCLASS/SCLASS+METHOD+DEF`) and
  the `SCLASS`-opened-body case both already resolved their own receiver
  via `resolve_singleton_receiver` instead of assuming `self` — `SDEF` was
  the one remaining case that didn't. Not currently exploitable (confirmed
  by grep: no `def SomeConst.foo` shape appears anywhere in this project's
  own real `.rb` sources today, only `def self.foo`), but closed anyway,
  matching this file's own established discipline for a real, general gap.
  Fixed by reusing `resolve_singleton_receiver` for `SDEF` too, verified
  byte-for-byte behavior-preserving against the real regenerated output of
  all three `*-compiled` gems (every existing `def self.foo` target
  resolves to the identical owner string as before, since `self`'s own
  receiver codegen always resolves via the same `LOADSELF` case
  `resolve_singleton_receiver` already handles).

  The same sweep also cross-checked all three gems' real `register.cxx`
  against a fresh, unrestricted `bc2cpp.rb` diagnostic run's own
  "compiled entry points" listing (name, registration kind, and
  visibility, not just presence) — found no gap in `mruby-rpg2k-compiled`
  (1463/1463) or `mruby-lcf-compiled` (34/34), and confirmed
  `mruby-rgss-compiled`'s one apparent mismatch
  (`RGSS::Graphics.singleton#brightness_sprite`) is the pre-existing,
  already-documented deliberate non-registration (a private singleton
  method with no real public entry point, still reachable via its own
  same-owner MONO call site regardless), not a new gap.
