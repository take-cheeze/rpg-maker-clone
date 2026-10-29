# GC roots for values compiled code holds (GC_KEEP_REMOVED, GC_KEEP_OVERWRITTEN)

mruby's collector marks the VM stack, the GC arena and the heap. It does not scan the C stack. An interpreted
method keeps every register in a VM stack slot, so a value it read stays alive while the register holds it. A
compiled method keeps registers in C locals, so the same value stays alive only while something else references
it. bc2cpp therefore roots, in the arena, every value that compiled code holds in a register and that nothing
else might hold:

| Value | Rooted by |
|---|---|
| A new object (`[]`, `"..."`, `Klass.new`, ...) | The allocating API puts it in the arena. |
| A value a call returns | The mruby API, or the `mrb_funcall` contract (`bc2cpp_entry_call`), keeps the result. |
| A value an API just **unlinked** (`Array#pop`/`shift`, `Hash#delete`) | `GC_KEEP_REMOVED` (`bc2cpp_keep_removed`). |
| A value a store just **replaced** in a slot (ivar, global, element, upvar) | `GC_KEEP_OVERWRITTEN` (`bc2cpp_keep_old`). |

## The bug GC_KEEP_OVERWRITTEN fixes

`Game::Interpreter#take_move_route_requests` is `r = @move_route_requests; @move_route_requests = []; r`. The
compiled body read the embedded ivar into a C local, stored a fresh Array over it, and returned the old one. After
that store only the local referenced the old Array. Its caller, `RPG2k::Scene::Map#apply_move_requests`, iterates
it in an inlined `each` loop whose body allocates; a GC step in that loop freed the Array and the method returned
a freed cell. CI's `bc2cpp-sweep` caught it on map 255 as a `declared -> Array | nil` hint violation, once, at a
commit whose allocation pattern put a collection inside the loop. It was latent in every commit.

## The rule

A store compiled code makes into an existing slot roots the value it replaces **before** the slot is
overwritten, when that value is not an immediate (one tag test; `mrb_gc_protect` ignores immediates itself). The
root is an arena entry, so it lives until the enclosing arena restore, as long as a VM register would have kept
it. Rooting at the store, not at the read, is what makes the rule independent of who holds the old value: this
method's register, a caller's, or the return value of a direct `_impl` call.

| Store | Emitted as |
|---|---|
| Embedded ivar (`@x = v`, `attr_writer`, the synthesized `x=`) | `bc2cpp_keep_old(M, field);` before the field store (`ivar_set_code`, and the synthesized writer in `codegen_emit.rb`). The typed fields hold immediates only and need none. |
| Ivar with no embedding | `bc2cpp_iv_set` (reads the old value first). |
| `SETGV` | `bc2cpp_gv_set`. |
| `SETUPVAR` into the enclosing compiled frame | `bc2cpp_keep_old(M, *slot)` before the slot store. |
| `a[i] = v` | The inline `bc2cpp_ary_set` roots `ARY_PTR(a)[n]`; `mrb_ary_set` is a macro for a wrapper that does the same. |
| `a[i, n] = rpl`, `slice!`, `clear`, `replace` | `mrb_ary_splice`, `mrb_ary_clear` and `mrb_ary_replace` are macros for wrappers that root `ary[head, len)` first. |
| `h[k] = v` on an existing key | `bc2cpp_hash_aset` roots `mrb_hash_fetch(h, k)` when the Hash is not empty. `mrb_hash_fetch` does not run a default proc. Hash literals and keyword Hashes are fresh and keep `mrb_hash_set`. |

`bc2cpp_raw_ary_set` skips the root where a loop only moves values around inside its own fresh temporary (the
`sort_by` insertion sort).

## The caller side: ELEMENT_READ_ROOTS

A by-name callee can unlink an element from its container without any compiled store: `Array#clear`, `Hash#[]=`
or `Array#replace` reached through `send`, or a bytecode method that stores. The store rule does not see that call.
When the callee returns, its own arena roots are dropped, so a compiled caller that read the element into a local
before the call and uses the local after it holds the only reference, and a collection in between frees it.

`tools/bc2cpp/element_read_roots.rb` (`ElementReadRoots`, a `RegisterFlow` subclass) roots such reads:

- It runs on the final per-instruction texts of a method, after register flow, so the registers it follows are the
  ones the emitted code uses. For each element read (`GETIDX`, `GETIDX0`, `AREF`) it walks the paths from the read,
  carrying the set of registers that hold the element: a clean copy `rX = rY` from a holder adds `rX`, a clean write
  removes its register. At a call on such a path, the read is rooted when a holder is one the call reads (its
  receiver or an argument: the callee holds it in a C local while it runs), or is live after the call (RegisterFlow's
  liveness, handler edges included) and not overwritten by the call. The read then gets `bc2cpp_keep(M, rD);` after
  its text. Otherwise it gets nothing. Definitions and reads are taken past the `//` comments a call's text leads
  with.
- A call is any text that names a function outside `SAFE_CALLS`. The safe names are the value constructors and
  predicates, the element reads, and the compiled Array stores and removals (`bc2cpp_keep_old`, `bc2cpp_ary_set`,
  `bc2cpp_mrb_ary_pop`, ...), which already root the value they replace or unlink. Everything else is a call:
  `mrb_funcall`, a direct `_impl` call, every Hash function (a key is hashed by its `hash` method, which can run Ruby
  code, so `mrb_hash_get`, `mrb_hash_fetch`, `mrb_hash_set` and the Hash store and delete wrappers are calls), and an
  allocator not in the list.
- A method that RegisterFlow refuses, and a method compiled without the flow pass (`REGISTER_FLOW=0`, a resumable
  body, a method with a prefix), roots every element read: there is no liveness to narrow it.
- The inlined loops over a live Array root their element register each iteration when the body contains a call
  (`ElementReadRoots.loop_keep`): `each`, `map`/`select`/`find`, `inject`/`any?`/..., and the `sort_by` key loop.
  The `&:sym` loop roots its element unconditionally, since it calls the element by name. The inlined `Hash#each`,
  `each_key` and `each_value` iterate `mrb_hash_keys` / `mrb_hash_values` snapshots: fresh, arena-rooted and not
  reachable from user code, so their elements stay referenced and need no root.
- `bc2cpp_ary_collect` (an `Array#map` whose block is not inlined) hands each element to the block by pointer,
  not on the VM stack (the block is called directly), so it roots the element before the call. The arena restore
  after each iteration drops the root.

## What it does not cover

The store rule and the caller-side rule see what the generator emits. These are still open:

- a **bytecode** store (a VM `SETIV`, `SETGV`) or a by-name native's store does not root the value it replaces. A
  compiled caller that read that value is covered by ELEMENT_READ_ROOTS, but a value held only by the callee's own
  C code is not: the fork's `mrb_iv_set` and the array and hash mutators would need the same root.
- a C runtime helper that keeps an element in a C local across a callback, without the generator's read sites (a
  native sort's comparison, for example), is not covered. Nothing in the generator emits those reads, and this has
  not been probed.
- a root taken inside a region that restores the arena every iteration (the helpers that call
  `mrb_gc_arena_save`, such as `bc2cpp_ary_collect`, and the regions in `codegen_collection_ops.rb`) is dropped at
  that restore. The rooted values are used within their iteration; a value used after such a region is not checked
  by the liveness walk.
- a read whose element is overwritten before any call on every path gets no root. That is the intent, not a gap:
  the store that overwrote it roots the element.
- bytecode callers are not exposed: the VM keeps every register in a stack slot the collector scans.

## Cost

An embedded ivar store gains a load and a tag test of the old value; an `mrb_gc_protect` call (one arena entry)
only when the old value is a heap object. A Hash store of an existing key does one extra lookup. See the sweep
timings in the commit that introduced the rule.

ELEMENT_READ_ROOTS adds a `bc2cpp_keep` (an `mrb_gc_protect` only for a heap element) after each element read whose
local is live across a call, and in each per-iteration inlined loop whose body calls. Counted in the closed-world
output (`shipped.cxx`, `coverage_report.rb` with `BC2CPP_COVERAGE_KEEP_DIR`):

- Closed-world output: 0 `bc2cpp_keep(` calls on master (468,858 lines). With this rule, 2,887 (471,750 lines): 2,407
  after element reads, 452 per iteration in inlined loops, 27 for `&:sym`, and 1 in `bc2cpp_ary_collect`.
  `bc2cpp_keep_old(` is unchanged at 1,485.
- Where the roots come from: RegisterFlow refuses some methods (`alias`, a text that takes a register's address,
  and `goto`), and every element read in them is rooted without the liveness test. In the instrumented run that was
  about 1,164 reads in 192 method compiles, against about 4,345 reads in analysed ones. The instrumented run counted
  each compile attempt, probe compiles included, so these are upper bounds; the emitted count above is exact.
The runtime cost is not measured here; the `bc2cpp-sweep` timings are the measure.

## Checking it

`MRBC=path/to/mrbc ruby scripts/bc2cpp/gc_root_check.rb` generates a fixture whose methods read a value, overwrite
or empty its slot, run `GC.start` and allocate (so a freed cell is reused), then use the value. It runs every
method interpreted and compiled, one process per method, and requires equal output. It then builds the fixture
with `BC2CPP_GC_KEEP_OVERWRITTEN=0` (the prelude's `bc2cpp_keep_old` becomes a no-op and the wrappers are not
installed) and requires every method to diverge, so the check cannot pass for a build that roots nothing.

The by-name cases (`ary_clear_by_name`, `ary_store_by_name`, `hash_clear_by_name`, `hash_store_by_name`) call
`send` on the container, so the compiled read is the only root. `each_clear_by_name` and `map_clear_by_name` do the
same inside an inlined loop, `map_proc_clear` does it through `bc2cpp_ary_collect`, and `arg_clear_by_name` passes
the element to a compiled method that clears the Array and then reads its argument (the caller's read is then the
only root, and the caller no longer uses the element after the call). On master these fail, and so does the static
check (`bc2cpp_keep` after an element read); with the argument term of the call test removed, `arg_clear_by_name`
fails.
