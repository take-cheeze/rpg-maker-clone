- **bc2cpp's own "never called" diagnostic (zero evidence of any call site
  anywhere in the program's own bytecode or native sources) is now acted
  on, not just printed.** `scripts/bc2cpp_prune_never_called_registrations.rb`
  removes a compiled method's `register.cxx` registration once it is both
  never-called and owned by a class with no external scripting surface
  (`Game::`/`RPG2k::`/`RPG2k3::`/`LCF::` only -- `mruby-rgss-compiled`'s own
  owners are the real, public RGSS scripting API a downstream game's own
  bundled scripts call, so are never touched), never a
  `BC2CPP_WIRED_EMBEDDINGS` owner, and never a `.singleton` owner; a new
  `scripts/bc2cpp_never_called_registrations_check.rb` guards against the
  same dead weight coming back. The method's interpreted bytecode `def` is
  left untouched as the safe fallback, so this can never regress into a
  `NoMethodError` even if the reachability scan missed something. Run for
  real and confirmed via a real `wio_rgss_boot` ARM link: removed
  `Game::Character#front_tile` and `LCF::Database#maker`, dropping bc2cpp's
  real flash-needed figure by 188 bytes (confirmed absent from the linked
  memory map, present only in `ld`'s own "Discarded input sections"
  listing). See docs/adr/0193.
