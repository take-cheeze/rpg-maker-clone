# 0152: bc2cpp `each` literal-block inlining + `&:sym` block-pass support

## Status

Accepted.

## Context

After ADR 0147 (`#times` inlining, the first real `BLOCK`/`SENDB` support),
a real closed-world survey found `BLOCK`/`SENDB`/`SSENDB` shapes in 434 of
the 499 methods still left on the interpreter -- the single largest
remaining gap by far. ADR 0147's own survey ranks the call targets:
`#each` (260 sites) dominates, followed by `#map`/`#each_with_index` (71
each), `#any?` (39), `#select`/`#reject` (26/24), `#find` (21), `#reduce`
(16), plus 53 `SSENDB` sites (implicit-self block calls and `&:sym`
block-pass).

Two shapes are in scope for this round:

1. **Literal `each` blocks** (`ary.each { |x| ... }`): the same
   `BLOCK R(a+1)` + `SENDB Ra :each n=0` adjacency ADR 0147 already
   recognizes for `#times` (confirmed against real `mrbc -v` output --
   the shapes are identical), pointed at a new method name. The hard part
   ADR 0147 explicitly deferred is the receiver-type story: unlike
   `#times` (zero bytecode overrides program-wide), `#each` has real
   competing definitions (`Game::Actors#each`, `Game::Party#each`,
   `LCF::Array2D#each`), so inlining must prove the receiver is really an
   Array at each site.
2. **`&:sym` block-pass** (`ary.reject(&:dead?)`): `LOADSYM R(a+1) :sym`
   immediately followed by `SENDB`/`SSENDB Ra :name n=0`, with NO `BLOCK`
   at all (confirmed against real `mrbc -v`). The VM's own `OP_SENDB`
   packs `regs[bidx]` through `ensure_block` into a symbol-proc, so there
   is no closure to inline and no environment to capture -- each iteration
   is one ordinary `mrb_funcall` of the named method plus accumulation.

Out of scope (later rounds): `map`/`select`/accumulator literal blocks,
callee-side `yield`/`&blk` forwarding, `BREAK` inside `#times` blocks
(unchanged), `sort`-family comparators, `LAMBDA`.

## Decision

**Receiver gate (both shapes): static trace, raise-tripwire guard.** Each
recognized site must trace its SENDB destination register through
`trace_new_target` (the same backward proof `compile_send`'s own TYPED
path trusts -- `GETIV` through `ClassLayout`-known ivars like `@enemies`,
`X.new` chains, and a new `ARRAY`/`ARRAY2` literal case: `OP_ARRAY`
unconditionally creates an Array per `3rd/mruby/src/vm.c`) to exactly
`"Array"`. `SSENDB` sites have an implicit-self receiver no register
trace can see -- admitted only when the enclosing method's own owner IS
`Array` (nearly vacuous in game code, the only sound static claim).
Unproven sites yield no region: honest `#error`, interpreter fallback,
always correct.

The emitted loop carries an `mrb_array_p` guard that raises `TypeError`
(mirroring `#times`' `mrb_integer_p` guard). It is unreachable when the
gate is sound -- a loud tripwire if the trace is ever buggy, never silent
wrong dispatch into an override. Deliberately NOT a live `mrb_funcall`
fallback: `mrb_funcall` cannot carry a block, so falling back through it
would silently drop the block -- the exact bug class ADR 0147 rejected
proc-wrap for. (User-confirmed scoping: runtime guard, no callee yield.)

**Loop semantics (verified, not assumed):** native iteration in
`3rd/mruby/src/array.c` re-checks `RARRAY_LEN(self)` every iteration, and
CRuby confirms `each` visits elements pushed mid-iteration -- so the
inlined loop uses a LIVE length condition (unlike `#times`' snapshot `n`)
with `mrb_ary_ref` per element (the same bounds-checked public API
`GETIDX` codegen already trusts). `each` returns the receiver (no
assignment on fall-through); `BREAK Rv` assigns the SENDB destination and
jumps past the loop (matching `OP_BREAK`'s `L_UNWINDING` value semantics;
confirmed `BREAK` always carries a value register, `LOADNIL`-supplied when
bare). `RETURN_BLK` stays a plain C++ `return`, level-0 upvars stay free
(both inherited from ADR 0147's machinery untouched).

**`&:sym` accumulation** mirrors real `Symbol#to_proc` + Enumerable
semantics per method name (`each` discards, `map` collects,
`select`/`reject` filter on truthiness, `find` first-truthy-or-nil,
`any?`/`all?`/`none?` boolean with early exit, `count` tallies) --
recognized set `each map select reject find any? all? none? count`.

**Implementation:** `recognize_each_regions` + `recognize_sym_regions`
(shape + gate), `emit_each_inline` + `emit_sym_inline` (loop + guard),
wired through the existing suppressed-address/glue-at mechanism in
`compile_method`; `compile_block_body_insn` gains optional
`break_dest:`/`break_label:` kwargs (nil default -- the `#times` emitter
passes neither, so `break`-in-`times` keeps its `#error` exactly as
before). Zero changes to `compile_insn` dispatch or arg-shape gates.

## Verification

- Real runtime harness (fresh `libmruby_core` + built mrbgems, real
  `mrb_load_string` call sites into compiled overrides): `each` literal
  (accumulator, `next`, `break`-with-value, non-local `return` hit/miss,
  outer-local capture+store, `__send__` dispatch, push-during-iteration
  visits the new element, guard raises `TypeError` when a proven-Array
  ivar is swapped for an Integer); `&:sym` (`map`/`select` on String and
  Integer core methods, `find`, `each`-returns-receiver, full
  `select`/`reject`/`find`/`any?`/`all?`/`none?`/`count` on
  `Integer#even?`/`odd?` via numeric-ext). All pass (11 + 7 + 4).
- Real end-to-end regen of all three `*-compiled` gems (in-process
  harness replicating each `mrbgem.rake` invocation exactly, validated by
  reproducing the known 1651/35/98 clean counts): `mruby-rpg2k-compiled`
  1651 -> 1678 clean (+27), zero newly-skipped methods on any gem
  (471 -> 444 rpg2k; lcf/rgss unchanged); `OP_BLOCK` 392 -> 367,
  `OP_SENDB` 373 -> 344; every other category byte-identical.
- 27 newly-clean methods, all previously `OP_BLOCK`/`OP_SENDB`-blocked
  (23) or bare-`SENDB` `&:sym` sites (4: `Game::Troop#live_members`,
  `SaveLoad#dispose`/`#update`, `RPG2k::Window#dispose`) -- including
  `Game::Actor#initialize`'s `@equipment.each` blocker and six more
  `Game::Battle`/`Game::Party` methods.
- No `register.cxx`/`owners` changes in this round (capability only, per
  the established opcode-round/coverage-round split); wiring is a
  separate coverage PR.

## Consequences

- `map`/`select`/accumulator LITERAL blocks, `each_with_index`,
  callee-side `yield`/`&blk` forwarding, `sort`-family comparators, and
  `BREAK`-in-`times` stay interpreted -- each a separate future round on
  this same machinery (only shape-matching + receiver reasoning are
  `#each`-specific; registers/offsets/labels/upvars/returns are shared).
- The 17 keyword-blocked methods ADR 0151's follow-up named stay
  interpreted (callee-side work, orthogonal); `CALL_KEYWORD` count
  unchanged at 46.
- `SSENDB` literal-`each` on self-Enumerable game classes stays
  interpreted (owner-gate) -- needs a `self`-class proof, future work.
