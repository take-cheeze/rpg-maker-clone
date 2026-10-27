# Reading an attr_reader's field in place (ATTR_READER_INLINE)

An `attr_reader` of an embedded ivar (ATTR_STRUCT_DEVIRT) is replaced by a synthesized reader whose whole body is
one field load:

```cpp
mrb_value Optcarrot__Config_loglevel_impl(mrb_state* M, mrb_value self) {
  return (mrb_undef_p(((Optcarrot__Config_ivars*)DATA_PTR(self))->ivar_loglevel) ? mrb_nil_value() : ...);
}
```

A devirtualized call to it (IVAR_ACCESSOR, a POLY_SMALL_N or CHA_SELF arm) used to call that function behind an
exact-class guard `Config == mrb_obj_class(M, recv)`. Two calls were left on every such read:

- the reader itself. Since the generated C++ is split into shards (`docs/bc2cpp-shards.md`) and methods are grouped
  by owner, a reader called from another class usually lives in another translation unit, so GCC cannot inline it;
- `mrb_obj_class`, which mruby exports out of line (`src/class.c`).

Optcarrot's `CPU#run` tests `@conf.loglevel >= 3` once per emulated instruction, so both calls ran about ten
thousand times a frame.

## What changes

- **The read.** When this run emits both the reader and the struct it reads (`attr_reader_inline?`: no
  `ONLY_OWNERS` filter, or the filter names the owner and its struct's storage owner), IVAR_ACCESS
  (`ivar_get_code`) writes the reader's body at the call site. The expression comes from one helper,
  `embedded_reader_value`, that also writes the synthesized reader, so the two cannot drift apart. That includes
  SLOT_ASSURED's bare read (`docs/bc2cpp-slot-assured.md`). The site is tagged `/* ATTR_READER_INLINE */`.
- **The guard.** It is `bc2cpp_class_is`, the inline exact-class test every compiled guard now shares
  (CLASS_READ_INLINE, `docs/bc2cpp-class-read-inline.md`), so the `mrb_obj_class` call is gone too for a
  plain-class receiver.

## Why it is sound

The guard is never weaker than before, and the code it protects is the reader's own body. So the inlined site does
exactly what the call did, wherever the call was emitted. Every decision about *whether* a site may call the
reader stays where it was:

- a subclass override keeps its own arm;
- a reader redefined by a `def` makes its owner a repeated owner, so it never joins a chain;
- a name a runtime definition can change is blocked (RUNTIME_DEF_DEVIRT_GUARD);
- nil, or a class that does not answer the name, takes the fallback.

The receiver's struct comes from that same guard: `DATA_PTR` is that owner's family struct whenever the reader may
run.

A caveat that is not new: a singleton method defined *outside* the closed world (code loaded at run time, which
the compiler never saw) passes `mrb_obj_class`, so the reader still runs. That was already true of the call. Inside
the closed world such a definition blocks the name.

`BC2CPP_ATTR_READER_INLINE=0` calls the reader again, for comparison.

## Check

`MRBC=path/to/mrbc ruby scripts/bc2cpp/attr_reader_inline_check.rb` checks these points:

- the generated code: the in-place read and its class-pointer guard, the subclass and other-class arms that keep
  their calls, a reopened reader that is never inlined, and the kill switch;
- a fixture run interpreted and compiled, with the same output for the fast path, a subclass override, a reopened
  reader, a nil receiver, another class answering the name, a class that does not, an unset ivar, an ivar set by
  reflection and a non-Integer value.

## Effect on optcarrot

Measured with callgrind on the probe (Lan_Master, `BC2CPP_SHARDS=4`). Per-frame figures are the 21-frame run minus
the 1-frame run, divided by 20, against master `01e9778e`. The checksum is 59662 at 180 frames in both builds.

| | master | ATTR_READER_INLINE | delta |
|---|---|---|---|
| frame loop | 23.835 M | 23.667 M | −167.5 K (−0.70 %) |
| `mrb_obj_class` | | | −139.2 K |
| `Config#loglevel` reader | 59.2 K | 0 | −59.2 K |
| `CPU#run` (now holds the read) | 1.100 M | 1.130 M | +29.6 K |
| conditional branch misses | 53.0 K | 48.3 K | −4.7 K (`CPU#run` 9.5 K → 6.0 K) |

Startup does not change (+0.002 %). GCC now inlines `bc2cpp_range_each` into `CPU#add_mappings`, which moves
about 2.8 M instructions between the two functions; the net cost is +0.16 M.

What remains of the `loglevel` test in `CPU#run` is a few instructions: the `@conf` load, the class-pointer
compare, the field load and the `>= 3` compare. Hoisting it out of the loop would take a closed-world proof that
nothing the loop calls writes `@conf` or `Config#@loglevel`, and is not done.
