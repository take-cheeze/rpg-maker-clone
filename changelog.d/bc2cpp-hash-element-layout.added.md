- `tools/bc2cpp/bc2cpp.rb` can now prove "every VALUE of this Hash-typed
  ivar is class X" (new `HashElementLayout`, `HASH_ELEM_HINT`), the
  Hash-value analogue of the existing `ArrayElementLayout`/`ELEM_HINT` --
  and wires that fact into `emit_hash_each_inline` via `with_element_hint`,
  the same per-element devirtualization guard (a real runtime
  `mrb_obj_class` check, never a bare assumption)
  `emit_each_inline`'s own Array loop already uses. Previously
  `emit_hash_each_inline` (this compiler's own recently-added `hash.each
  { |k, v| ... }` inliner) never called `with_element_hint` at all, so
  even a Hash whose values are provably one class still dispatched every
  call on the yielded value through `mrb_funcall`.

  Deliberately narrower than the Array version in two ways: VALUES only,
  never keys (a key fact would be almost entirely redundant -- real Hash
  literals in this codebase are overwhelmingly Symbol-keyed already, and
  the one real consumer, an inlined `hash.each`'s yielded value, only
  ever needs the value side), and no SEND-based preserving-chain rule the
  way Array has for `select`/`map`/etc. -- `merge!`/`update` and any
  other unmodeled writer shape simply poisons, the same "never guess" bar
  every writer list in this file already holds itself to. New pieces:
  - `HASH_ELEMENT_WRITERS = %w[[]= store]` -- confirmed both real aliases
    of the same native `hash_set` (3rd/mruby/src/hash.c); `h[k] = v`
    itself is a real `OP_SETIDX`, not a `SEND :[]=`, confirmed directly
    against real `mrbc -v` output (the same generic index-assignment
    opcode Array's own `a[i] = v` uses -- `HashElementLayout.analyze`'s
    own SETIDX arm is a straight reuse of `ArrayElementLayout.analyze`'s,
    gated on Hash-typed ivars instead).
  - `hash_element_source_scan`/`ivar_hash_element_hint`/
    `written_hash_element_class` -- the Hash-value analogues of
    `array_element_source_scan`/`ivar_element_hint`/
    `written_element_class`, kept as separate functions (never a shared,
    parameterized one) for the same "don't bend one function around two
    unrelated tables" reasoning `trace_eqq_literal_receiver`'s own
    comment already states for a different pair. The `HASH` literal
    terminal reads VALUES at the ODD register offsets from the literal's
    base register (`HASH R2 2` means 2 key/value PAIRS spanning
    R2..R5 -- confirmed against real `mrbc -v` output and
    3rd/mruby/src/vm.c's own `OP_HASH`: `for (i=a; i<a+b*2; i+=2)
    mrb_hash_set(regs[i], regs[i+1])`), unlike Array's literal where
    every register is an element.
  - `CodeGen#proven_hash_element_class`/`#hash_element_ctx` (mirroring
    `#proven_element_class`/`#element_ctx`) and
    `#region_hash_element_class` (mirroring `#region_element_class`),
    threaded into `recognize_hash_each_regions`' own region hash as a new
    `elem_class` field, then into `emit_hash_each_inline`'s block-body
    loop as `with_element_hint(block_irep, insn, i, '2', ...)` -- `'2'`
    because the block's own second mandatory parameter (key is `'1'`) is
    where this emitter binds the yielded value, confirmed against that
    emitter's own `val_reg = 2 + offset`.
  - `element_value_class` (the generic "what class is the scalar value in
    this register" tracer) required zero changes to support Hash values
    -- it was already fully generic, not Array-specific.
  - `scripts/bc2cpp_coverage_report.rb` gains a parallel
    `known-hash-element-class hints (HASH_ELEM_HINT)` / poisoned-count
    line in `docs/bc2cpp_coverage.txt`, mirroring the existing `ELEM_HINT`
    one.

  Verified via a real whole-program regen, isolated with `git stash`:
  8 real `HASH_ELEM_HINT` facts proven whole-program (e.g.
  `Game::Actors#@all` -> `Hash<Game::Actor>`, `Game::State#@vehicles` ->
  `Hash<Game::Vehicle>`, `Game::State#@pictures` -> `Hash<Game::Picture>`,
  `RPG2k::Scene::Map#@vehicle_chars` -> `Hash<Game::Character>`), 38
  poisoned-to-unknown candidates reported alongside. Compiled output,
  `#error` set, and `docs/bc2cpp_coverage.txt`'s existing counts are
  byte-identical before/after this change (confirmed via a full stdout
  diff): the whole-program snapshot's real `hash.each { |k, v| ... }`
  call sites happen not to call a method directly on the yielded value in
  the exact devirtualizable shape today, so this round lands as proven,
  wired, zero-regression infrastructure -- consumed automatically the
  moment a matching call site is added or discovered, exactly like most
  of `ArrayElementLayout`'s own facts before their first real consumer
  landed. `bash scripts/bc2cpp_coverage_check.bash`: fresh.
  `scripts/rpg2k_logic_check.rb` (1201 checks), `scripts/
  rpg2k_scene_check.rb` (1062 checks), `scripts/lcf_testbed_check.rb` all
  still pass. Independently verified with a real `g++ -std=c++17
  -fsyntax-only` compile of the actual `SKIP_UNSUPPORTED=1` generated
  output: the same 6 pre-existing, unrelated `int` -> `mrb_value`
  conversion errors in `anim_target`/`command_item` (out of scope here),
  zero new errors.
