# 0314. Exact-receiver sends reach the compiled core directly, and what the core coverage really is

Date: 2026-10-02

## Status

Accepted

## Context

The request was to extend compiled and direct-call support for core Ruby so that more by-name sends become
direct calls. ADR 0264, 0269, 0270, 0271 and 0310 compile mruby's own Ruby, put the block-taking methods behind
a Fiber guard and give literal-block sends exact-class arms. This ADR first measures what is left, then builds
the one slice the measurement justifies. Everything below is the wio closed world at master `43031b24`
(`scripts/bc2cpp_coverage_report.rb`, `scripts/bc2cpp_dynamic_site_census.rb --tsv`, host `mrbc` of mruby 4.0).
`scripts/bc2cpp_send_root_report.rb` does not exist on master and was not run.

### Every core-source method (220)

| Status | Methods |
| --- | ---: |
| compiled, registry definition (name no native or operator shares, no block) | 23 |
| compiled, hidden from the registry (native or operator name, or guarded) | 153 |
| bytecode: compile `#error` (`Array#combination/permutation`, `Enumerable#cycle`, `File#initialize`, `File.foreach`, `IO.open/popen`, `Range#min/max/to_a`) | 10 |
| bytecode: mruby-enumerator (Fiber) | 25 |
| bytecode: builds a lambda (`Enumerable#inject`, `Hash#to_proc`, `Symbol#to_proc`) | 3 |
| bytecode: refused (`Kernel#\``) | 1 |
| bytecode: shadowed by a later definition | 5 |

Of the 176 compiled, 121 touch a block and carry the ADR 0269 guard. 102 of those have a name no native method
and no operator shares, so the guard (not ADR 0264 finding 1) is the only reason they are not registry
definitions. Registry visibility is not the lever: it turns off the name-keyed proofs, which is why it stays
withheld.

### By-name sends that name a core or native method (2,815 `bc2cpp_send`, 401 `mrb_funcall_with_block`)

Engine = `Game::*`, `RPG2k*`, `RGSS*`, `LCF*`. Counted from the census; "exact" means the receiver register is
written by a literal or fresh container (the census `literal_or_fresh` origin, which is what the exact proof of
ADR 0280 reads).

| Callee | engine sites | receiver exact | unproven | direct form today |
| --- | ---: | ---: | ---: | --- |
| `max` / `min` (else of the inline arm) | 51 / 32 | 45 / 31 | 6 / 1 | compiled `Enumerable#max/min`, hidden and guarded: none |
| `name`, `resume` | 54, 31 | 2, 0 | 52, 31 | native or the interpreter's own `resume`; receivers unknown |
| `delete`, `include?`, `first`, `join`, `index` | 26, 51, 23, 9, 16 | 1, 0, 0, 1, 1 | rest | class-tested native arms exist; the else is for other classes |
| `uniq`, `sort`, `count`, `to_h`, `fetch` | 5, 9, 14, 8, 1 | 3, 0, 1, 0, 1 | rest | compiled, hidden, guarded |
| block sends with no compiled callee (57 in the engine) | `Array.new(n){}` 11, `Profiler.section` 9, `loop` 7, `File.open` 7, `reduce` 4, `index` 3, `each_line`/`each_char` 2, `reject`/`select`/`sort(&:sym)` 12, other 2 | | | none |

The census "core_or_native" kept-else category is 278 engine sites; 14 of them have an exact receiver. That is a
receiver-proof problem, not a core-coverage problem, as suspected.

### What the Fiber guard costs (ADR 0269, 0283)

- **World level.** The wio, psp and maix engine world (the three engine gems, the single-format build) has no
  `Fiber`, no `Enumerator#next/peek`, no `Lazy`, no task, no `eval`: YieldReach finds four seed nodes, all in
  mruby-enumerator, and the `Fiber` constant appears only there (4 references). `next`, `peek`, `next_values`,
  `peek_values` and `rewind` are sent only from mruby-enumerator itself (the 46 `resume` sends are
  `Game::Interpreter#resume`). So no Fiber can be created at run time there, in principle. It is not exploited:
  YieldReach is a closure over by-name edges, not a reachability from roots, so mruby-enumerator's generator
  blocks still make 85 core methods and 46 core blocks "may yield"; the engine has 3 methods
  (`Actors#each`, `Party#each`, `Array2D#each`, refused) and 1 block. The psp and maix worlds have the same Ruby
  (not run). The desktop, wasm and android worlds are open and run RPG Maker XP/VX/Wolf scripts through
  `mruby-rpgxp` (`script_host.rb:230,251`) and `mruby-wolf` (`interpreter.rb:217,564,636,738`) Fibers, and the
  optcarrot probe runs its PPU in a Fiber: the guard stays there.
- **Block level (wio).** 1,003 blocks: 876 of 877 engine blocks are yield-free, 46 of 126 core blocks may yield.
  Of 370 compiled blocks with a direct entry 350 are yield-free; the 77 blocks of 447 without one (they `break`
  or `return`) cannot carry the flag, which is the larger cause of guarded arms than any unresolved send. The
  one engine block and three methods that may yield do so through the single by-name `each` of the Enumerator
  model, so each is "unknown because of one unresolved send".
- **Escape.** 31 of 1,003 blocks escape (stored, returned, or handed to a method that keeps its `&blk`); 28 are
  engine blocks, 25 of them the LCF schema `lazy` DSL.
- **By-name cost.** Of 373 BLOCK_CORE_DIRECT sites, 7 keep a dynamic else only because of the root-context
  guard (proven class, block not yield-free); 47 have none; 319 keep one for non-exact receivers. The guard costs
  perhaps 7 by-name sends and one comparison per call. What costs by-name sends is that the 102 guarded bodies
  are hidden: 78 engine sites carry such a name (`max` 51, `sort` 9, `uniq` 5, `open` 5, `step` 3, ...).

## Decision

**CORE_EXACT_DIRECT** (`tools/bc2cpp/codegen_core_exact_direct.rb`). A send with no block whose receiver is
proven an exact `Array`, `Hash`, `Range` or `Integer` by ADR 0280 is a direct `_impl` call of the compiled core
body when all of these hold:

1. the walk of `block_core_target` finds one compiled definition: no native registration, project definition,
   prepend, unattributed mixin, outside definer or dynamic installer of the name on the chain (the checks of ADR
   0270, unchanged), and the definition is public;
2. a guarded body (it touches a block) is `body_yield_free?`: YieldReach's `nb`, "nothing it calls can suspend a
   Fiber". The call has no block of its own, so this is the whole condition and the entry's root-context test
   is not needed. In an open world nothing is proved and nothing changes;
3. an Enumerable body also needs a compiled `each` for the class (the entry tests `each` at run time);
4. the plain by-name line is what remains: a site with a native arm in front of it keeps it.

The else arm of the inline `[a, b].min` / `.max` (ADR 0261) is such a send, so it takes the same call. The block
is `mrb_nil_value()`, which `direct_call_args` already supplies for a block-taking callee.

`BC2CPP_CORE_EXTEND=0` returns the earlier output byte for byte (`cmp` of `shipped.cxx` against master: identical). The FIXNUM_COMPARE (912), LITERAL (201), FIXNUM_BINARY (222), INTEGER_UNARY (109), NUMERIC_OPERAND_PROOF (420) and BLOCK_CORE_DIRECT (371) counts are unchanged.

### Not built, with the measurement

| Candidate | Sites | Why not |
| --- | ---: | --- |
| `Kernel#loop` arm for implicit self | 7 | the proof of the name is easy (`kernel_native_dispatch_safe?` shape), but the blocks `return` or `break`, so no direct entry, no yield-free flag, and the guarded else stays: relocation only |
| `reduce` / `inject` | 4 | `Enumerable#inject` builds a lambda and stays bytecode (ADR 0269); receivers unproven |
| `index` / `find_index` | 3 | `Array#index` is C; receivers unproven |
| `each_line` / `each_char` | 2 | a String arm was built and dropped: both receivers unproven, so relocation |
| `Array.new(n) { }` | 11 | exact (the constant) and removable, but needs a helper loop replicating `mrb_ary_init`, a proof of the `Array` constant and of `Array#initialize`/`Array.new`; next lever |
| `Profiler.section`, `File.open` | 9, 7 | native callee; `IO.open` does not compile (`#error`) |
| exact-entry points for `delete`, `include?`, `first`, `join`, `reverse` | 109 | receivers are not exact (1 of 26 `delete`); the class-tested arms already exist |
| dropping the Fiber guard by proof | | measured above; a performance matter, 7 by-name sends |

## Consequences

Measured on the wio closed world, same tree, with and without the change:

| | Before | After |
| --- | ---: | ---: |
| cached dynamic sites (coverage report) | 3,240 | 3,159 |
| `bc2cpp_send` sites | 2,815 | 2,734 |
| POLY-marked sites | 897 | 893 |
| `mrb_funcall_with_block` sites | 401 | 401 |
| `CORE_EXACT_DIRECT` sites | 0 | 81 (`max` 46, `min` 31, `uniq` 3, `fetch` 1) |
| engine sites | 2,377 | 2,296 |

All 81 are removals, not relocations: no by-name send and no class test is left at those sites. The change is
engine-only (core bodies are compiled with the closed world withheld). The 5 `max` and 1 `min` sites on an
unproven receiver, and every other receiver, are unchanged. Direct calls omit the callee frame (a backtrace
omits it) and the entry's arity check (the compile-time one replaces it), like every direct call.

Risk. The body is called outside the entry guard, so soundness rests on YieldReach `nb` (ADR 0283); a world in
which any comparator, `hash` or `eql?` can reach a `Fiber.yield` withdraws the call (checked: a yielding `<=>`
makes `Array#uniq`, `Hash#fetch` and the Enumerable bodies non-relaxable too, because natives call back into
operators). The Ruby override of `Array#max`, `Enumerable#max`, `Array#each`, a prepend, a dynamic installer
and a singleton maker each withdraw it.

## Verification

`scripts/bc2cpp_core_exact_direct_check.rb` (own `core-exact-direct` shard of `bc2cpp-checks`):

- generated code: the positives with zero by-name dispatches, the unproven receivers that keep their send, the
  kill switch, the open world, no core, and the withdrawing worlds above;
- behaviour: the fixture's classes are registered compiled (bc2cpp registers only the wired owners, so the
  ADR 0310 style harnesses leave a fixture's own methods bytecode) and run against the same build interpreted
  (one build per variant; `BC2CPP_CX_INTERPRET=1` skips registration at run time), on full-core, core-only and 32-bit `mrb_int` builds, under
  incremental-GC stress, with raising, throwing, `StopIteration` and Fiber cases, and a second world whose
  comparator yields to a Fiber. Definitions made after registration are bypassed by direct calls and seen by
  the interpreter, which is the runtime assertion of zero dispatches;
- the 32-bit leg runs with `BC2CPP_BLOCK_DIRECT_ENTRY=0` (ADR 0271: a function address does not fit a 32-bit
  `mrb_int` slot on a 64-bit host);
- nine generator mutants, each a copy at `tools/bc2cpp-mutant-*` inside the repository (a copy under `/tmp` has
  an empty closed world and every mutant would die vacuously), all of which must fail, and an unmutated control
  that must pass.

Not run in this change: `bc2cpp_send_root_report.rb` (absent), psp/maix/wasm/desktop worlds (read from sources).
