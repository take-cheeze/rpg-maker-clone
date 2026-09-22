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
  (EMBED)` line counts) is only half the story -- `CodeGen#drop_unsafe_
  embeddings` and the hand-maintained `BC2CPP_WIRED_EMBEDDINGS` allowlist
  both filter it further before anything actually reaches a struct field,
  so the real, active effect has to be read off the generated code itself,
  not that raw count. Doing that (`grep`-ing the real, shipped generated
  C++ for the 9 `BC2CPP_WIRED_EMBEDDINGS` classes' own `_ivars` structs,
  before vs. after): `Game::Interpreter` goes from 1 embedded field to 12
  (11 new `mrb_bool` flags -- `@running`, `@erase_requested`, `@halt_
  movement_requested`, `@actor_graphic_changed`, `@parallax_changed`,
  `@tiles_changed`, `@vehicle_toggle_requested`, `@face_owner`, `@system_
  graphic_changed`, `@battle_animation_pending`, `@waiting`), and `Game::
  Screen` goes from 12 to 17 (`@shake_continuous`/`@flash_continuous`/
  `@pan_locked` as `mrb_bool`, plus `@shake_frames`/`@fade_transition` as
  `mrb_int` via the new constant-sourced case) -- both real, hot classes in
  the RPG2k event/screen-effect pipeline. `Optcarrot`'s own classes gain
  nothing from this in practice: none of them are in `BC2CPP_WIRED_
  EMBEDDINGS` (a real-project-only allowlist), so no Optcarrot ivar has
  ever actually reached a struct field regardless of this change -- see
  `tools/optcarrot_probe/README.md`'s own correction. 100.0% method-level
  coverage and zero `#error` markers stay unchanged.
