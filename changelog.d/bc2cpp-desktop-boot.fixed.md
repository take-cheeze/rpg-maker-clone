- The desktop `RPGMAKER_BC2CPP=1` build now boots and reaches the map. It
  failed at boot four different ways, none of which any CI job exercised:
  - `mruby-rpg2k-compiled` initialised before `mruby-rpg2k` defined `Game`
    (`build_config.rb` now initialises a gem that depends directly on a maker
    gem right after that maker).
  - Embedded-ivar classes were not `MRB_TT_DATA` (the generator now emits
    `bc2cpp_set_instance_tts` for the classes it embeds) and, separately, the
    analysis embedded classes such as `Game::Actor` whose `#initialize` the
    hand-written `register.cxx` never installs, so compiled accessors
    dereferenced a NULL `DATA_PTR`; embedding is now limited to
    `BC2CPP_WIRED_EMBEDDINGS` in `tools/bc2cpp/compiled_gems.rb`.
  - `bc2cpp_block_break` / `bc2cpp_method_return` unwound through VM frames
    without restoring `mrb->jmp` or the callinfo stack, tripping `mrb_vm_run`'s
    assertion; every catch site now restores both.
  - A three-operand `ARRAY Rd Rs N` (mrbc's `local = [literal]`) compiled to an
    empty Array, so `quarters = [[nil, nil], [nil, nil]]` became `[]` and
    starting a new game raised `undefined method '[]=' for NilClass`.
  New `scripts/bc2cpp_runtime_wiring_check.rb` covers the last three.
