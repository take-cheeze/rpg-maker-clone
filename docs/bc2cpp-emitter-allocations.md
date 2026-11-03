# Emitter allocations in bc2cpp

Changes that cut host objects the bc2cpp code emitters allocate without
changing what they compute. The sites come from an object-mode profile of the
sealed Optcarrot compile (`scripts/bc2cpp/compiler_profile.rb --mode object
--optcarrot`, see [compiler data profiling](bc2cpp-compiler-data-profile.md)),
read per line through each frame's `:lines` and per caller through `:edges`.
On master the profile had 67,528 samples (one per 100 objects).

## 1. compile_send options as one Hash (SEND_OPTIONS_HASH)

`compile_send` is wrapped by eight prepended layers in a normal build
(`ArgShapeCalls`, `CheckedSend`, `ClassNarrowingGuard`, `CoreSelfNative`,
`CheckedPoolReceiverSend`, `ComputedSend`, `NilableReceiverSend`,
`SelfNewConstruct`). Each was `def compile_send(insn, **kwargs)` and called
`super`, so every layer copied the keywords into a new Hash. That was one Hash
per layer per send compile: the `def` lines of those layers held roughly 1,100
samples (about 1.6% of all objects).

The layers now take `compile_send(insn, kwargs)`: callers still write keywords,
which Ruby passes as one positional Hash to a method with no keyword
parameters, and each zero-argument `super` passes that same Hash on. The
innermost `CodeGen#compile_send` splats it into `compile_send_site`, which keeps
the original keyword signature, so missing or unknown keywords still raise.
Sharing is sound only because no layer writes to the Hash. Every layer and
every helper it is passed to (`checked_send_level`,
`class_narrowing_guard_plan`, `checked_pool_plan`, `nilable_receiver_plan`,
`computed_send_plan`, `computed_send_guarded`) only reads it. The report
modules loaded by `BC2CPP_*_REPORT` and `scripts/bc2cpp/self_send_census.rb`
take the same signature. `SelfNewConstruct` tests `insn.sym == 'new'` before it
splats the Hash into `self_new_construct`. That method returned nil for any
other name, so the extra test changes only how often the Hash is copied.

`ArgShapeCalls#compile_poly_small_n`, `#compile_poly_table` and
`#compile_keywordless_call` only forward, so they now take `(...)`, which
forwards without a copy.

## 2. Per-instruction churn in compile_method and compile_insn

- **`compile_insn`** saved the source site as a new `[file, line]` Array per
  instruction (595 samples). It now keeps two instance variables, saved and
  restored the same way. `insn_source_site` formats the same text from them.
- **REGISTER_FLOW labels**: `flow_labels[idx] = "#{flow_labels[idx]}#{jump_label}"`
  built a new String for every instruction, even though the label is usually
  empty (469 samples). It now appends only a non-empty label. The slots are
  only read afterwards, so a slot may hold the shared frozen `''`.
- **`run_inline_loop_passes_in`** built a context Array, or `[]`, for each of
  the 16 loop passes on every method compile (354 samples). The context is now
  built once per call, and a pass without one gets a frozen empty Array. Both
  are splatted into the recognizer's arguments, so no recognizer receives the
  Array itself.
- **`ArgShapeCalls#compile_send`** saved three instance variables into an
  Array. It now uses three locals.

## 3. ARM_PRUNE graph walk

`arm_prune_reachable` dispatched on `when *BytecodeIR::CONDITIONAL_BRANCHES`,
and Ruby builds the splatted Array again at every evaluation (538 samples, one
per visited instruction). It now uses an `if` chain with
`CONDITIONAL_BRANCHES.include?(op)`. The constant holds Symbols, whose `===`
is `==`, so the arms match exactly as before.

## 4. POLY_SMALL_N chain and its proofs

- **`compile_poly_small_n`** joined `([owner] + inherited).map { ... }` for each
  branch's class test, and `([recv] + call_argv).join` for the call. It now
  starts from the owner's test and appends one per inheriting subclass. The
  call joins only `call_argv`, after `recv`, when it is not empty. The listed
  owners are collected with `push`/`concat` instead of a `flat_map` of
  two-element sums. `owner_class_ptr_expr` is still called in the same order
  for each owner. The INHERITED_GUARD note's subclass list is built only when
  the note is emitted.
- **`inheriting_subclasses`** returns one frozen empty Array when no subclass
  qualifies. Every caller only reads the result (`reject`, `+`, `each`,
  `concat`).
- **`native_arg_types`** built a `[label, position]` key per mandatory position
  to probe `@native_arg_positions`. That Set is now indexed as label to Set of
  positions. The index is rebuilt whenever the frozen Set is replaced, and it
  uses Set membership, so `eql?` decides membership as before.
- **`slot_assigns_on_exit?`** built a `[label, ivar, chain]` memo key for every
  query. The memo is now nested by label, then ivar, then chain. Each level
  uses the same `hash`/`eql?` as the pair key's elements. The root call's empty
  stack is a frozen constant, and the method still builds `stack + [label]`.
- **`exact_flow_strip_nil`** compared `@nonnil_receiver` with a new
  `[irep.label, idx, reg]` per query. It now compares size and elements
  directly. That key is always a three-element Array or nil.

## 5. Leftovers

- **`NativeExpressionDevirt.symbol_name`** interpolated `MRB_SYM_TOKEN_RE` into
  a new Regexp on every call. It now uses `/o`, as `closed_world.rb` already
  does for the same pattern.
- **`RegisterFlow#build_edges`** duplicated every IR successor list and then
  took `uniq` of each one. The lists are frozen and already unique, and they
  are only read once built: `add_dispatch_edges` replaces a list instead of
  editing it. So the IR's list is now shared until a fall-through edge is
  added, which duplicates it. A list of fewer than two edges is its own `uniq`.

## Measurements

Sealed Optcarrot compile, `scripts/bc2cpp/compiler_profile.rb --mode none
--optcarrot` (Ruby 4.0.5 with YJIT, mrbc from pinned mruby), against master
`7a2bed254`. Each version had one warm-up run, then the versions alternated for
three runs on the same shared host:

| Run | Version | `allocated_objects` | `elapsed_seconds` |
| --- | --- | ---: | ---: |
| 1 | master | 6,755,322 | 9.878 |
| 1 | this change | 6,179,430 | 8.732 |
| 2 | master | 6,755,305 | 9.071 |
| 2 | this change | 6,179,497 | 9.700 |
| 3 | master | 6,755,227 | 9.236 |
| 3 | this change | 6,179,468 | 9.071 |

Allocations fell by about 575,800 objects per run (8.5%). Within each version
the runs differ by fewer than 100 objects. Elapsed time moved in both
directions, so these runs do not show a speedup.

The object-mode samples fell from 67,528 to 61,767.

The generated C++ is byte-for-byte identical to master's. The comparison
prepared one sealed world at a fixed path and compiled it with both versions,
with and without `--annotated`. The `--optcarrot` runs above also match once
their per-run temporary world path is normalized.

## Left alone

- `NumericFlow.step_transfer` and `copy_reg_write` copy a state on every
  changing transfer (about 2.3% of samples together). That is the analysis's
  copy-on-write. It is not emitter churn.
- `direct_call_args` returns an `[argv, note]` pair that most callers
  destructure and discard. `class_pool_ivar_mask` builds a `[family, name]`
  key, and several report modules read those keys. Each is about 0.3%.
- `strict_hint_wrap`, `indent_lines` and `drop_unused_registers` still use
  `gsub`, and the remaining native-source `String#scan` passes allocate their
  MatchData. These were each under 0.3%, and replacing their Regexp semantics
  needs its own proof.
- `"#{RegName[r]}"` copies in `compile_send_site` and `compile_insn_op` would
  need a proof that no emitter mutates an argument String.
