- `tools/bc2cpp`'s whole-program ivar-embedding pass (`IvarLayout`) now
  recognizes two more provably-safe SETIV source shapes, widening how many
  instance variables get embedded as real C struct fields instead of going
  through mruby's ordinary, per-access `iv_bsearch_idx` ivar table:
  - `@x = true` / `@x = false` (a new `:bool` embeddable type, backed by a
    real `mrb_bool` struct field and mruby's own public `mrb_bool_value`/
    `mrb_true_p`/`mrb_false_p`).
  - `@x = SOME_CONST` when `SOME_CONST` is one of the whole-program-proven
    integer-valued constants `INTEGER_CONSTANT_PROOF` already tracks for
    other purposes (`GETCONST`/`GETMCNST`, embedded as `:fixnum`).
  `IvarLayout`'s own raw proof (what the coverage report's `ivar embedding
  (EMBED)` line counts) is not what actually reaches a struct field:
  `CodeGen#drop_unsafe_embeddings` and the hand-maintained
  `BC2CPP_WIRED_EMBEDDINGS` allowlist (`tools/bc2cpp/compiled_gems.rb`,
  currently `Game::Screen`/`Game::ChipSet`/`Game::Switches`/`RPG2k::
  Scene::VehicleWorld`/`LCF::EventCommand`/`LCF::MoveCommand`) both filter
  it first, so the real effect has to be read off the generated code
  itself. Doing that (the real generated C++, before vs. after): `Game::
  Screen` gains 5 real fields (12 -> 17) -- `@shake_continuous`/`@flash_
  continuous`/`@pan_locked` as new `mrb_bool` struct fields, plus `@shake_
  frames`/`@fade_transition` as `mrb_int` via the new constant-sourced
  case. No other currently-wired class gains anything (none of their own
  ivars happen to be bool- or constant-sourced). `Optcarrot`'s own classes
  gain nothing in practice either: none of them are on
  `BC2CPP_WIRED_EMBEDDINGS`, so no Optcarrot ivar has ever actually reached
  a struct field regardless of this change -- see `tools/optcarrot_probe/
  README.md`'s own note. 100.0% method-level coverage and zero `#error`
  markers stay unchanged, and `scripts/bc2cpp_wired_embedding_check.rb`
  (every compiled entry point of a wired class installed by its
  register.cxx) still passes.
