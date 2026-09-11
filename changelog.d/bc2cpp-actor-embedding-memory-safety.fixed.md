- **A real, live memory-safety bug in the opt-in (`RPGMAKER_BC2CPP=1`)
  AOT-compiled `Game::Actor`, shipped since its own introduction.**
  `tools/bc2cpp/bc2cpp.rb`'s `drop_unsafe_embeddings` guard, which decides
  whether a class's ivars get embedded into a real RData struct, checked
  only whether `#initialize` had pure-mandatory argument arity -- not
  whether `#initialize` actually finished compiling. `Game::Actor#initialize`
  has pure mandatory arity but still ends in a real `.each` block, so it
  was never going to compile either way -- yet the old guard let 7 of its
  own ivars through as "embeddable" regardless. The result: 16 real,
  already-shipped `Game::Actor` methods (`faceset_index`, `set_faceset`,
  `restore_class`, `gain_exp`, and more) were generated reading a struct
  field off a pointer that's never actually allocated for a real
  `Game::Actor` instance (`register.cxx` never tags the class
  `MRB_TT_DATA`) -- real undefined behavior on every one of them, every
  time they ran, in the real, already-merged build. Fixed at the root:
  `drop_unsafe_embeddings` now also requires the same real
  `compiles_clean?` check `compile_send`'s own devirtualization-soundness
  fix already uses, so a class whose `#initialize` can't compile never
  gets its ivars embedded regardless of arity. Confirmed by direct
  re-inspection of the regenerated output: no `DATA_PTR(self)` access
  remains anywhere in `Game::Actor`'s own compiled methods; all 76 of its
  registered entry points are otherwise completely unaffected. See
  `docs/adr/0139-bc2cpp-lcf-file-aot-compile.md`'s own follow-up.
