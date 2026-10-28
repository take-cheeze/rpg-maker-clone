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

## What it does not cover

The rule sees the stores the generator emits. These stay as the interpreter would have them only if nothing else
holds the old value:

- a store made by **bytecode** (a VM `SETIV`, `SETGV`) or by a **core native called by name** (`Hash#clear`,
  `Array#delete_at`, `compact!`, `Struct#[]=`): a compiled caller that read an element beforehand and holds it
  in a local is exposed. These need the same root inside the fork's `mrb_iv_set` / array / hash mutators.
- a loop that restores the arena every iteration: a root taken inside the iteration for a value used after the
  loop is dropped at the restore.

## Cost

An embedded ivar store gains a load and a tag test of the old value; an `mrb_gc_protect` call (one arena entry)
only when the old value is a heap object. A Hash store of an existing key does one extra lookup. See the sweep
timings in the commit that introduced the rule.

## Checking it

`MRBC=path/to/mrbc ruby scripts/bc2cpp/gc_root_check.rb` generates a fixture whose methods read a value, overwrite
or empty its slot, run `GC.start` and allocate (so a freed cell is reused), then use the value. It runs every
method interpreted and compiled, one process per method, and requires equal output. It then builds the fixture
with `BC2CPP_GC_KEEP_OVERWRITTEN=0` (the prelude's `bc2cpp_keep_old` becomes a no-op and the wrappers are not
installed) and requires every method to diverge, so the check cannot pass for a build that roots nothing.
