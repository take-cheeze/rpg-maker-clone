# Embedded ivar families (EMBED_FAMILY)

bc2cpp stores a class's instance variables as fields of a C++ struct behind the
object's `DATA_PTR` when every access to them can be proven, instead of in the
generic `iv_tbl`. One object has one `DATA_PTR`, so before EMBED_FAMILY an
inheritance chain in which several classes had their own ivars stayed in
`iv_tbl` entirely: the base and the subclass would otherwise each install a
different struct.

`fold_embed_families` (tools/bc2cpp/codegen.rb) instead folds such a family into
its root. The root's struct (`<Root>_ivars`) holds the union of every member's
ivars, and a name the members type differently becomes a boxed `mrb_value`
slot. A subclass's compiled methods then read `((Root_ivars*)DATA_PTR(self))->ivar_x`
directly. Its instances get that storage from the root's `#initialize`, the
same way a subclass without ivars of its own already did.

A family is folded only when all of these hold:

- every subclass `#initialize` under the root starts with `super`, either
  explicit or bare (`super` with no arguments forwards the method's own), so no
  subclass code runs before the storage exists;
- no member is a native-data owner;
- the world is self-registering (`BC2CPP_SELF_REGISTERING=1`, as in the
  optcarrot probe and the fixtures). The engine's wired worlds
  (`BC2CPP_WIRED_EMBEDDINGS`) keep one layout per chain for now, because their
  registrations wire each owner separately.

When the root does not embed after all (for example, all of its ivars are
natively exposed), the members return to `iv_tbl`. Set
`BC2CPP_EMBED_FAMILIES=0` to restore the old refusal for comparison.

In the optcarrot probe this embeds the APU's `Oscillator`, `Pulse`, `Triangle`
and `Noise`. Their dynamic ivar lookups were about 16% of the frame loop, and
folding them cut the 1800-frame run from 8.9 s to 8.0 s.

`MRBC=path/to/mrbc ruby scripts/bc2cpp/embed_family_check.rb` checks the
generated struct and the refusals. It also compares interpreted and compiled
runs over reflection, `dup`, `GC.stress` and a `Fiber`.

## Instance type

An embedding class's instances must be `MRB_TT_DATA`, which
`bc2cpp_set_instance_tts` sets at each compiled gem's init. A class copies
its superclass's instance type when it is created, and a gem's mrblib loads
before that init runs, so a subclass made there (`Class.new(C)` in a class
body) would keep `MRB_TT_OBJECT`. The setup therefore also switches every
class already below a switched one (`INSTANCE_TT_SUBCLASSES`, a heap walk
taken only when a switched class has a subclass at all). The fixture checks
keep libmruby's `MRB_DEBUG`, so `mrb_data_init`'s type assertion watches
this; `scripts/bc2cpp/self_new_leaf_check.rb` covers `SN_ANON`.
