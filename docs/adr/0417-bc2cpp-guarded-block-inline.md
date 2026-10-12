# 0417. bc2cpp: inline a literal block's loop behind a run-time exact-class test

Date: 2026-10-12

## Status

Accepted

## Context

A literal-block send (`x.each { }`, `x.map { }`, `x.any? { }`) is inlined into a method's own `_impl` when the flow
proves the receiver's class (ADR 0147, 0152, 0154, 0155, 0156): the block body becomes a C++ loop body, no `RProc` is
built and nothing yields. Where the receiver is not proven (an argument, an ivar, a call result: 252 of the 282
by-name sites of ADR 0325) the send builds an `RProc` and reaches the compiled core body through BLOCK_CORE_DIRECT's
exact-class arms (ADR 0270) or `mrb_funcall_with_block`, and every element costs a `mrb_yield` into the block's cfunc.

The arms already test the exact class at run time. The proven-receiver loops need that test too, if the proof is
replaced by it: the only thing the recognizers lacked for an unproven site was the class.

## Decision

`GUARDED_BLOCK_INLINE` (`tools/bc2cpp/codegen_guarded_block_inline.rb`): for a send whose receiver class is *not*
proven, the existing inline emitters are run as for a proven receiver and their loop is emitted

```
if (M->c == M->root_c && mrb_array_p(rN) && mrb_obj_ptr(rN)->c == M->array_class) {   // or the Hash test
  <the inlined loop, its break/next/return as for a proven receiver>
  goto Lbc2cpp_guarded_end_<send>;
}
<the ordinary BLOCK + SENDB code, unchanged: BLOCK_CORE_DIRECT arms, BLOCK_FALLBACK, dynamic send>
Lbc2cpp_guarded_end_<send>:;
```

* Every receiver the test does not name (a subclass, an object with a singleton class, a Hash for an Array loop, nil, a
  user class, anything in a Fiber) takes the code that was there before, unchanged. Nothing is removed and no proof is
  weakened; the proven-receiver path is untouched (`region_receiver?` answers exactly as before when the flow or the
  trace names a class).
* The class is only admitted when `block_core_arms(name, argc)` names it, i.e. when BLOCK_CORE_DIRECT would call the
  compiled core body of that very name on that class. That is the existing proof that no Ruby definition, prepend,
  unattributed mixin, outside definer, native registration or dynamic installer can answer `name` on the class
  (`block_core_target`, ADR 0270), and it needs the closed world. No reviewed-list entry (ADR 0226, 0275) is added or
  needed; no allowlist changes.
* The root-context test of ADR 0269 is kept in every guard, so a Fiber's frames still reach the bytecode through the
  else path.
* Loops that exist today are the ones guarded: `each` (Array, and Hash for a |k, v| block), `each_index`,
  `each_key`, `each_value`, `map`/`collect`-family, `select`, `reject`, `find`, `flat_map`, `filter_map`,
  `each_with_index`, `any?`/`all?`/`none?`/`count`, `reduce`/`inject(init)`, `sort_by`-family and `&:sym` forms. One send
  may get an Array loop and a Hash loop (`each` with a two-parameter block); their tests are exclusive and each
  jumps over the rest. The second copy gets its own label and nested-function prefix (`region[:label_tag]`).
* A guarded region carries no element-class hint: that hint describes a receiver the flow proved.
* Only the whole-method pass is guarded (not the rescue try-body pass, not resumable steps).
* `BC2CPP_GUARDED_BLOCK_INLINE=0` turns it off. `BC2CPP_GUARDED_INLINE_WHY=1` prints on stderr, per send, why a loop was
  not emitted (receiver traced to another class, block body not clean, no arm for the name, and the block shape of
  every send no recognizer took).

### Found on the way

`array.each_with_index { ... break ... }` declared no `broke` flag but the emitted `break` set it: a proven receiver
with a `break` in an `each_with_index` block did not compile as C++. The flag is now declared when the body sets it.

### The IR method inliner (`BC2CPP_IR_INLINE=1`) was evaluated as the vehicle, and not used

`BytecodeIR::MethodInlineRegion` (ADR for #2132) takes leaf methods with no child ireps, no catch handlers, no
GETUPVAR/SETUPVAR/BREAK/block return and no loop; it renders each instruction through the same `compile_insn` text
emitter as every other path, behind a separate register namespace and a symbolic exit label. For a block body the
same two techniques are already what `compile_inline_block_body` does (registers shifted by the method's `nregs`,
level 0/1 upvars addressed directly, `next`/`break`/`return` as labels and C++ `return`), so the IR region would add a
second implementation of the body translation with identical output. What an IR region does not give is the loop
driver, which is the part that differs per method (live length re-read, accumulator, early exit, `break` flag,
Hash snapshot); those stay in the emitters whichever front end feeds them. And the thing that kept 252 sites out was
never the translation of the body but the receiver proof and the else path, which this ADR addresses once for all
emitters. The IR region stays the right fit for a later step that shares the *body* between method and block
inlining; it was left alone here.

`BC2CPP_IR_INLINE=1` on this checkout's master (shipped pass, wio): `bc2cpp_send` 1,837 -> 2,819, `bc2cpp_nomethod`
304 -> 3,721, `mrb_funcall*` 386 -> 386, `shipped.cxx` 21.5 MB -> 38.2 MB (2,925 `BYTECODE_IR_INLINE` bodies). It
changes no funcall count and multiplies the per-site send and nomethod counts the reviewed lists are keyed on, because
every inlined body carries its own copies of its callee's sends.

## Consequences

Measured on master `39c366ac` and the same tree with this change (`shipped.cxx` of `scripts/bc2cpp/coverage_report.rb`,
wio closed world):

| | master | this change |
| --- | ---: | ---: |
| guarded inline loops | 0 | 217 |
| `bc2cpp_send(M` sites | 1,837 | 1,963 |
| `bc2cpp_nomethod(M` sites | 304 | 299 |
| `mrb_funcall*` call sites | 386 | 400 |
| `mrb_funcall_with_block` | 411 | 425 |
| `mrb_proc_new_cfunc_with_env` (RProc builders) | 417 | 437 |
| `// BLOCK_FALLBACK` sends | 414 | 434 |
| `shipped.cxx` | 21.55 MB | 22.72 MB |

The static counts rise, as they must: the guard keeps the whole old path as its else, and 217 block bodies now exist
twice (once inline, once as the block's cfunc), with the nested block functions of a duplicated body. What falls is
the work done at run time when the receiver is an exact Array or Hash: no `RProc`, no `mrb_funcall_with_block`, no
per-element `mrb_yield`. On the fixture of `scripts/bc2cpp/guarded_block_inline_check.rb` compiled with the compiled
core (`-O1`, a loaded 4-core machine, so read ratios): `each` + `s += x` over 2,000 elements 308 ms -> 20 ms,
`map` 451 -> 51, `select` 661 -> 122, `any?`/`all?`/`none?` 2,025 -> 51, `each_with_index` 155 -> 107, `Hash#each` 414 -> 253,
a four-element `each` 300,000 times 253 -> 65; the interpreter takes 1,870 ms for the first.

Which block sends got a guarded loop (shipped pass, by callee: loops, an `each` with a |k, v| block counts twice):
`each` 104, `each_with_index` 32, `map` 27, `any?` 16, `select` 15, `reject` 10, `each_index` 5, `uniq` 2, `each_key` 2,
`sort_by`, `find`, `filter_map`, `count` 1 each; 191 Array tests and 26 Hash tests. In the per-send report
(`BC2CPP_BLOCK_SEND_REPORT`, which now has a `guarded` column) that is 170 of the 293 by-name sends of `mruby-rpg2k`, 6 of
12 in `mruby-lcf`, 2 of 12 in `mruby-rgss`.

What the 414 `BLOCK_FALLBACK` sends of master are (shipped pass; each builds an `RProc` for the else path) and what stays:

* no inline emitter exists for the name: `page_field` 15, `cached_bitmap` 8 (engine methods that `yield`), `open` 7, `loop` 7,
  `reduce`/`inject` without an initial value 5, `each_with_object` 4, `index` 3, `auto_battle_best_target` 3,
  `each_event_position` 2, `reject!`/`delete_if`/`collect!`/`find_index`/`permutation`/`combination`/`each_char`/`each_line`/`sort`
  with one or two sends each, `Array.new` with a block (ADR 0391 already inlines it; the report counts it);
* the emitter exists but the block needs a shape it does not take: `times` and `downto` blocks with `break`/`return`
  (10), `loop` with `break`/`return`, a `map`/`select`/`reject` block with two parameters (a pair-spreading `map`, 9 in
  `mruby-rpg2k`), `each` whose block takes `*rest`, a block that `return`s from the method in an `each` (3 + core);
* the receiver is a Range, an Integer, a user class, a Struct, an IO or a File (`each` with no compiled core arm, 7
  in `mruby-rpg2k`): the guarded classes are Array and Hash only;
* the rest is `each`/`map`/`each_with_index`/`any?` sends of plain shape that the recognizers still decline or that
  are only guarded in the final compile of their method: the per-send report records the last compile of a send,
  probe compiles included, so its remaining count is an upper bound; the shipped output above is the measurement.

`scripts/bc2cpp/guarded_block_inline_check.rb` (generated code, then a closed-world fixture compiled with the compiled
core, linked into a full-core mruby and compared with the interpreter: break and next with a value, return from the
method inside the block, a raise (rescued and ensured), an array changed during `each` by push, delete, clear and
shift, a Hash changed during `each`, `|a, (b, c)|` destructuring, captured locals, an escaping lambda, nested blocks,
subclasses, singleton methods, nil, user receivers, a Fiber), and
`scripts/bc2cpp/guarded_block_inline_mutation_check.rb` (each condition above dropped in turn). Both are in the
`core-mrbtest` shard of `.github/workflows/bc2cpp-nightly.yml` next to `block_core_direct_check.rb`.

The harness of `block_core_direct_check.rb` registers the compiled core only; the fixture's own methods stay
interpreted there. The new check also registers its fixture's compiled entry points (from the `compiled entry points`
section of the diagnostics), which is what makes its comparison run compiled block bodies.
