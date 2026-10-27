# What native code defines on nil (NIL_NATIVE_ANSWERS)

`NUMERIC_OPERAND_PROOF` and the numeric ivar proof (`NUMIVAR`) read `@x += 1` on a slot that may still be nil as
"Integer, or a NoMethodError". That holds only when nil answers `+` by raising. `CodeGen#numeric_nil_raises?`
decides it. Its native half used to come from `nil_class_operator_names`, which collected every operator spelled in
any native file that mentions `nil_class`. `mruby-rational`'s `rational.c` defines `nil.to_r` in the same file as
`Rational#+`, `#-`, `#*` and `#/`, so all of those counted as nil operators. In optcarrot, `@hclk`, `@scanline`,
`@sp_buffered` and `@sp_index` of `Optcarrot::PPU` are first assigned in `reset`, not `initialize`. None of them
got a proof.

The file-level scan was also unsound in the other direction. `Kernel#<=>` lives in `kernel.c`, which never names
`nil_class`, so the scan left out `<=>` even though `nil <=> 1` returns nil.

## The scan

`NativeOwnerMap.nil_native_answers` (`tools/bc2cpp/native_owner_map.rb`) reads the owner of each native registration
from the same owner map the poly-chain proofs use (`NativeOwnerMap.build`):

- **Lookup path.** It starts from nil's ancestors (`CoreHierarchySigs.ancestors('NilClass')`: NilClass, Object,
  Kernel, BasicObject). It then adds every module that a native `mrb_include_module`/`mrb_prepend_module` puts into
  one of them, or into a class the map cannot resolve.
- **Names.** Every instance-table registration whose owner is on that path, or cannot be resolved, counts as a name
  nil may answer. That covers `mrb_define_method`-style calls, aliases, undefs and ROM `MRB_MT_ENTRY` tables. A
  class-method or singleton registration does not count, because it lands on a class object's table or on the main
  object, and neither is on nil's lookup path.
- **Refusal.** The scan refuses every name when a native source outside `3rd/mruby` registers a computed name on an
  unresolved owner or on the path, or includes a module it cannot resolve. A computed name or an unresolved mixin
  inside `3rd/mruby` is one of the core's forwarders for Ruby's own `define_method`, `include` and `extend`. The
  closed world already models those, so the scan trusts them (`verdict`'s `core_dynamic_trusted`).

The Ruby half of `numeric_nil_raises?` now checks the same path. It rejects a program definition on any module the
program or native code includes into a nil ancestor, a foreign-Ruby definer (`nil_foreign_definition_free?`), and
an unknown mixin on the path. Before, it checked only definitions owned by the four ancestor classes themselves.

For the optcarrot build, nil's native operators change as follows:

| | Operators |
| --- | --- |
| Before | `! != & * *! *!& ** + - -@ / = == === > ^ \| \|&` |
| After | `! != & <=> == === ^ \|` |

The build log prints the current set as `== nil native answers: ... ==`.

## Check

`MRBC=path/to/mrbc ruby scripts/bc2cpp/nil_native_answers_check.rb` runs three groups of checks.

- **Scan.** `rational.c` puts `to_r` on nil but not `+`. A native NilClass/Kernel/Object operator counts, and a
  class method does not. An unresolved owner keeps its name. A computed name outside the core and an include of an
  unresolved module refuse every name. A module a native include adds to Object carries its registrations.
- **Generated code.** With `mruby-rational` in the build, a may-be-nil `@nn_ticks += 1` gets `NUMIVAR INT`. The ivar
  stays unproven under a program `NilClass#+`, `Object#+`, `Kernel#+`, a module with `+` included into Object,
  `def nil.+`, and a native `+` on an unresolved owner.
- **Behaviour.** The interpreted and compiled runs print the same output: NoMethodError on the nil slot, then
  Integer counts after `reset`.

## Measurement

The measurements come from the optcarrot probe (Lan_Master, callgrind). Instructions per frame are (21 frames - 1
frame) / 20. Both builds come from the same tree. The checksum stays `59662` at 180 frames.

| Build | Instructions per frame | Cond. branch misses per frame | 1-frame run (startup) |
| --- | ---: | ---: | ---: |
| Before | 23,836,287 | 54.1K | 1,086,280,170 |
| After | 23,830,350 | 57.6K | 1,085,750,591 |

The generated code gains these facts and loses none:

- `NUMIVAR`: `PPU#@hclk`, `@scanline`, `@sp_buffered`, `@sp_index`, `APU#@frame_divider`, `@frame_irq_repeat`,
  `APU::DMC#@out_shifter` and `APU::Envelope#@volume`.
- Class pools for four of those ivars.
- Three `NUMARG` facts.
- Two more `NUMERIC_OPERAND_PROOF :+` arms and three `:/` arms.

The instruction drop sits in `PPU#main_loop_step`, at -6.3K per frame. The branch-miss rise is spread over functions
whose code did not change: `load_tiles`, `Enumerable#hash`, `Mixer#sample`. Those functions keep the same
instruction and branch counts, so the rise comes from callgrind's address-indexed predictor seeing a new code layout.
Two builds of the same master tree already differ by 1.1K misses per frame.

The speed gain is small. The fix is about precision and soundness: proofs that need "nil raises" now hold, and
`<=>` is no longer missing from the nil set.
