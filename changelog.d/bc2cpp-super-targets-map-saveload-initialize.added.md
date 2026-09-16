- `tools/bc2cpp/bc2cpp.rb`'s `SUPER_TARGETS` allowlist gains 2 more
  entries: `RPG2k::Scene::Map#initialize` and `RPG2k::Scene::
  SaveLoad#initialize` -- both the exact same first shape as the
  already-shipped 12 `#initialize` entries (`super parent`, one explicit
  mandatory arg, into the same, already-clean `RPG2k::Scene::
  Base#initialize`), confirmed against the real disassembly (`SUPER R6
  n=1` / `SUPER R5 n=1`) rather than just the source text.

  Both real soundness facts the table's own comment requires re-checking
  per entry were re-verified fresh: every real `Scene::Map.new`/
  `Scene::SaveLoad.new` call site across the whole closed world (mrblib
  plus `scripts/rpg2k_scene_check.rb`, and the rest of the repo besides)
  was grepped and none pass a block literal; `include`/`prepend` was
  re-grepped fresh too -- still exactly 3 real `include`s in the whole
  closed world (`Game::Party`/`LCF::Array1D` each `include Enumerable`,
  top-level `class Object; include RGSS; end`), none between `Map`/
  `SaveLoad` and `Base`. `Map#initialize` also takes an `apply_access:
  true` keyword arg, but only the explicitly-forwarded `parent`
  positional feeds the `super` call itself (confirmed against the real
  generated C++); the keyword only feeds a local hash used later in the
  method body.

  Of the whole-program `#error unhandled opcode SUPER` survey's 7 real
  remaining sites (`docs/bc2cpp_coverage.txt`'s own count), the other 5
  were checked and correctly left as `#error`, not forced in:

  - `RPG2k3::Scene::Battle#finish_round_animation` (bare `super`, the
    second existing shape, into `RPG2k::Scene::Battle#finish_round_
    animation`) has a sound target name, but the target's own body does
    not compile clean today -- it hits real `#error unhandled opcode
    SENDB`/`BLOCK` of its own from genuine Ruby blocks
    (`select(&:defending)`, `select(&:dead?)`, `.uniq { |a| ... }`,
    `.each { |ally| ... }`, already flagged by `tools/bc2cpp/
    compiled_gems.rb`'s own `RPG2k3::Scene::Battle` comment).
    `super_target`'s own `compiles_clean?(target_def.irep)` gate means
    adding this entry would be inert today (still `#error`) until that
    target's own blocks are separately supported.
  - `LCF::Sections#method_missing`, `LCF::Sections#respond_to_missing?`,
    `LCF::Array1D#respond_to_missing?`, `LCF::File#respond_to_missing?`
    each call `super`/`|| super` reaching `Object#method_missing`/
    `Object#respond_to_missing?` -- both native (C, mruby core), never
    Ruby-bytecode-defined anywhere in the whole closed world (grepped;
    no `def method_missing`/`def respond_to_missing?` under `Object`/
    `Kernel` exists at all). `super_target` can never find a registry
    `MethodDef` for a method nothing here defines in bytecode, so these
    stay `#error` regardless of an allowlist entry -- the same
    already-excluded "native superclass" shape this same allowlist's own
    comment already names for `RGSS::Bitmap::LoadError#initialize`.

  Verified via a real whole-program regen diff: `#error unhandled opcode
  SUPER` drops from 7 to 5, total `#error` count drops from 816 to 814
  (exactly 2), and the 2 methods' own generated bodies now call
  `RPG2k__Scene__Base_initialize_impl` directly instead of falling back
  to the interpreter (both still carry unrelated, pre-existing `#error
  unhandled opcode BLOCK`/`SENDB` of their own elsewhere in their bodies
  from genuine Ruby blocks, so neither newly appears in the "compiled
  clean" count -- only the SUPER-specific error is resolved).
  `scripts/rpg2k_logic_check.rb` (1201 checks), `scripts/
  rpg2k_scene_check.rb` (1062 checks), and `scripts/lcf_testbed_check.rb`
  all still pass.
