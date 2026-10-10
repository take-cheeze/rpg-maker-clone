# 0380. bc2cpp: entry-guarded specialization of hot methods (`BC2CPP_SPECIALIZE`)

Date: 2026-10-10

## Status

Accepted

## Context

`BC2CPP_TRACE_PARAMS=1` (with `scripts/bc2cpp_param_trace_report.rb`) records the class every compiled method parameter holds
at run time. On the merged mtf-meido-action boot and battle run it finds parameters that are monomorphic in practice and have
no static fact, so the compiler resolves every send on them by a class-tag chain with a `bc2cpp_nomethod` fallback, or by a
dispatch. The four hottest:

| Method | Parameter | Calls |
| --- | --- | --- |
| `RPG2k::Scene::Map#ids_touch?` | `dirty` = Hash | 88710 |
| `RPG2k::Scene::Map#event_sliding?` | `e` = `MapEventState` | 75262 |
| `RPG2k::Scene::Map#page_condition_ids` | `id` = Integer, `src` = `LCF::Array1D` | 44385 |
| `Game::EventGraphic.singleton#continuous?` | `anim_type` = Integer | 41484 |

What exists, and why none of it reaches these:

- The class pools (ADR 0295, 0296) and the Fixnum entry proof (`ENTRY_ARG_CALLSITE_PROOF`) prove an argument class from **every**
  call site. One site passing something else, or one the enumeration cannot see, withdraws the fact. These parameters have
  such a site, or a `nil` the trace never saw.
- `ClassArgTypes` is a reporting artifact and feeds nothing (its header says why).
- A `# bc2cpp: (Hash)` annotation is *guarded*: each use of the argument keeps its own class test with a fallback. That is
  sound for a wrong claim, and still pays a test per use.

## Decision

A method named in a plan file gets a **second body compiled under the assumption** that its listed parameters are exactly the
listed classes, and the original body gets **one entry check** in front of it:

```c++
mrb_value X_impl(mrb_state* M, mrb_value self, mrb_value e) {
  if ((!mrb_immediate_p(e) && mrb_obj_ptr(e)->c == bc2cpp_owner_class_62(M))) return X_spec_impl(M, self, e);
  ... the generic body, byte for byte what it was ...
}
```

The guard is in `_impl`, so the `mrb_func_t` wrapper, every direct `_impl` caller and recursion all reach it. A miss falls
through to the generic body, so **a wrong guess only costs speed**.

### Gate

`BC2CPP_SPECIALIZE=<file>`, lines `Owner#name param=Class ...` (`#` comments; `Owner.singleton#name` for a class method,
`tools/bc2cpp/specialize_seed.txt` is the trace-derived seed). Unset, empty or `0` is off: nothing in
`codegen_entry_specialize.rb` runs, and the generated C++ is byte-identical to master (measured below). A plan file that
does not exist fails the build, so a typo cannot silently build generic. A method the compiler refuses is one stderr line,
`bc2cpp: specialize: Owner#name stays generic: <why>`, and keeps only its generic body.

### How the assumption reaches the compiler (the one reuse)

The exact-class flow (ADR 0289) reads, per (irep label, argument position), the class set an argument may hold on entry from the
class pools (`class_pool_entry_mask`); every unguarded consumer (a send on the argument becomes a direct call, a Hash receiver a
native body) reads that flow. The specialized body is **the same irep compiled under a clone label** (`<label>~spec`) whose pool
entries are the assumed masks, plus what the call sites already prove about the method (copied, so the clone is never less
informed than the generic body). Every per-label memo (flow states, fixnum proof, numeric states, class tests) is therefore the
clone's own: nothing computed under the assumption can be seen by the generic compile, nor the other way round. The clone is
registered in the label-keyed tables (`@ireps`, `@owner_of`, the body-owner maps, annotations) for the duration of its compile
and removed after. Nothing else changes: no new flow, no new proof, no new runtime helper.

### The guard (what "exact" means)

| Class | Entry test |
| --- | --- |
| `Integer` | `mrb_fixnum_p(v)`: a fixnum. A bigint, a Float and nil take the generic body. The flow's `INT` also covers bigints, so the guard is narrower than the assumption, never wider. The clone's argument is also entered in the Fixnum entry set, as the call-site proof would. |
| `Float` | `mrb_float_p(v)` |
| `Array`, `Hash`, `String`, `Range` | the type tag **and** `mrb_obj_ptr(v)->c == M-><class>`, the test `CORE_BODY_EXACT_TESTS` uses: a subclass instance misses |
| a closed-world class | `!mrb_immediate_p(v) && mrb_obj_ptr(v)->c == <class>`: the object's **own** class pointer, not `mrb_obj_class`, so a subclass instance and an object with a singleton class both miss |

Not specializable: `nil`/`NilClass` (the flow uses only nil-or-one-class, ADR 0296, so nothing reads a pure-nil entry; every
nil assumption measured was a no-op), `Symbol`/`true`/`false`, modules, unknown classes.

### Soundness conditions

1. *The guard fixes what the body assumed.* The assumed mask of a position is exactly what the guard admits or a superset of it
   (Integer: INT covers the fixnum the guard admits). Everything else runs the original, unchanged body.
2. *The world must support exact classes.* Specialization needs `ClosedWorld#exact_instances_singleton_free?` and the class
   pools on; otherwise the method stays generic. (The user-class guard compares the raw class pointer, so it does not even rely
   on singleton-freedom for itself.)
3. *Nothing leaks.* The clone has its own label, so its memos are its own; the generic `_impl` text is checked to be byte-for-byte
   the gate-off text apart from the guard line (`bc2cpp_entry_specialize_check.rb`).
4. *The clone is the same method.* An identity clone (a plan line with no `param=Class`) compiles to exactly the generic body;
   that is how a label-keyed table the clone path misses shows up (the first version lacked the call-site pool entries and the check
   caught it).
5. *Only after the analysis is settled.* The constructor and the analysis passes compile methods before the class pools are
   final; those probes never specialize, and only the compile after `compute_return_classes` is kept.
6. *Exceptions, backtraces, frames.* The specialized body runs inside the same C++ frame as the generic one: no `mrb` call frame
   is added or removed, so the backtrace, `__method__`, `block_given?` and an exception raised from the body are the generic
   ones. The check runs hits that raise (NoMethodError inside the specialized body) and compares them with the interpreter.
7. *Define_method, method_missing, singleton and refinement escapes* are runtime events and the guard is a runtime test: a
   method added later to a guarded class changes nothing the compile-time world did not already model, and an object that gets a
   singleton class stops matching the user-class guard.

### Shapes left generic (a stderr line each)

Methods with a nested block irep (`BLOCK`, `LAMBDA`, an inlined `each`/`any?`/`times`), `rescue`/`ensure` ranges, `yield`/`&blk`,
optional, rest and keyword parameters, Fiber-resumable `_step` bodies and Fiber-guarded bodies, core (mruby's own Ruby) methods,
natively typed parameters, and a parameter that is not a required positional one. A specialized body equal to the identity clone
(the assumption changes nothing) is dropped rather than shipped twice. Blocks are the first to lift: the specialized body would
share the block irep of the generic one (its captured-local facts come from the original parent), and the helper function names
derive from the method's name, so the clone needs a name suffix for the nested cfuncs.

## Measurement

Whole program (`SKIP_UNSUPPORTED=1 scripts/bc2cpp_coverage_report.rb`, wio closed world, all three gems, `/*SO:*/` tags stripped), the
seed plan, against a control built from the same base commit (`origin/master` 27f18e0f):

- **Gate off**: `shipped.cxx` (21,553,927 bytes), its stderr and the report are byte-identical to the control.
- **Gate on**: two insertions and nothing else, **+8,817 bytes, +140 lines**: the `event_sliding?` specialized function (139
  lines) and its guard line. The type check of the whole file (`g++ -fsyntax-only`) passes.
- `RPG2k::Scene::Map#event_sliding?` (`e` = `MapEventState`): the specialized body resolves the six sends on `e`
  (`move_count`, `jumping`, `disp_x`, `disp_y`, `char` twice) to direct calls. Class-tag chains with a `bc2cpp_nomethod`
  fallback 8 to 2, `mrb_obj_class` tests 24 to 18, `bc2cpp_nomethod` sites 8 to 2; the two left are `char.x`/`char.y`, whose receiver
  class (8 candidates) the compiler does not know. The generic body is unchanged (the guard line aside).
- `Game::EventGraphic.singleton#continuous?` (`anim_type` = Integer): the specialized body is byte-identical to the generic one
  (`==` against constants is already as direct as the compiler makes it), so it is dropped: the plan line costs nothing.
- `RPG2k::Scene::Map#ids_touch?` and `#page_condition_ids`: skipped, nested blocks (`any?` with a block, `each` as a block
  fallback). `ids_touch?` would gain little: its `dirty` sends are already exact behind the `nil?` test; `page_condition_ids`
  would turn the `src[:pages]` index helper into a direct `Array1D#[]` call.
- The whole-program `bc2cpp_send`/`mrb_funcall_with_block` count (2489) does not move: the sites removed are class-tag
  chains, not by-name sends.

Not measured: the run time of the specialized body (the machine had no engine build and no game data); the saving per call is six
class compares and their branches minus one guard.

## Consequences

- The cost of a wrong plan line is one dead function and one failed compare per call. Specialization is opt-in per method,
  so a plan is the place to record the trace, and the report's "monomorphic but unproven" list is its input.
- Code size grows by one body per specialized method; the identity comparison keeps no-op lines free.
- The clone mechanism (a label per compile, tables registered for its duration) is also the way to extend this: blocks (a name
  suffix for nested functions), optional parameters (a wrapper arm) and several assumed signatures per method.
- Checks: `scripts/bc2cpp_entry_specialize_check.rb` (gate-off identity under four spellings, generic body untouched, exact guard
  strings, identity clone including a call-site-proven parameter, the refused shapes and worlds, a full-core run of 48 calls
  interpreted against compiled with a counter that shows a hit entering the specialized body and a miss not) and
  `scripts/bc2cpp_entry_specialize_mutation_check.rb` (16 mutants, among them the removed entry check, a guard that accepts a
  subclass or a Float, an assumption registered under the original label, and admitted blocks or rescue ranges).
