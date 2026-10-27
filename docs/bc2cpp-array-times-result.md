# `Array * Integer` is a fresh Array (ARRAY_TIMES_RESULT)

Programs often size a table by repeating a literal: `@bg_pixels = [0] * 16`, `@sp_map = [nil] * 264`. The class
pools ([ADR 0296](adr/0296-bc2cpp-class-pools.md)) join the class of every value stored into an ivar. They could
not name the class of `[0] * 16`, so every such ivar lost its pool, and each `@sp_map[@hclk]` kept the
`mrb_array_p(...) && ...->c == M->array_class` test in front of the element read.

`CodeGen#native_array_times_result` (`tools/bc2cpp/codegen_native_results.rb`) answers `ARR` for a `*` send when:

- the receiver is exactly an Array and the argument is proven an Integer;
- the native body is the audited `mrb_ary_times` (`NativeCoreDirect::RESULT_ENTRIES`). It returns `mrb_ary_new`
  for a zero count or its own `ary_new_capa`, both exactly `Array`, and raises for a negative count. Nothing in
  the program defines, installs or prepends `*` on Array (`native_core_entry_safe?`);
- nothing can give an Integer a `to_str`. `mrb_ary_times` first tries `mrb_check_string_type` on the argument
  and joins when that converts, as `[1, 2] * ","` does. So the registry may hold no `to_str` on Integer's
  ancestors, no installer or outside Ruby source may spell it, and no native outside mruby's core may spell it;
- no ancestor of Array defines `*`.

The last condition lets the fact skip the usual refusal for a name a computed send may remove. Optcarrot's
`send(*DISPATCH[@opcode])` counts as a possible `remove_method` of every name. If Array#* were removed, the send
would either raise NoMethodError and produce no value, or reach an ancestor's `*`, and there is none. Either way,
every value the send does produce is a fresh Array.

`BC2CPP_ARRAY_TIMES_RESULT=0` drops the fact.

## Check

`MRBC=path/to/mrbc ruby scripts/bc2cpp/array_times_result_check.rb` asserts that `@cells = [0] * 8` and
`@cells = [nil] * 4` give `@cells` an Array pool, in a world with a computed `send(*op)`, and that its index read
drops the class test. These keep no pool: a String argument, an argument of unknown class, a program
`Integer#to_str`, a program `Object#*`, and the opt-out. Interpreted and compiled runs print the same, including
the String join and the negative-count ArgumentError.

## Measurement

These figures come from the optcarrot probe (Lan_Master, release `-O3`, callgrind). Instructions per frame are
the difference between runs of 21 and 1 frames, divided by 20. Checksum `59662` at 180 frames is unchanged. The
probe's ivar proof is only on with the [ivar proof scope](bc2cpp-numeric-ivar-scope.md) change, so the build
measured here also has that change, [resumable locals](bc2cpp-resumable-locals.md) and
[HOT_INLINE](bc2cpp-hot-inline.md), on master `479b31ff`.

| Build | Instructions per frame | Ivar class pools |
| --- | ---: | ---: |
| Before | 32,191,709 | 42 |
| With ARRAY_TIMES_RESULT | 30,589,709 | 48 |

`PPU#@bg_pixels`, `@sp_map`, `@sp_buffer`, `@output_color`, `@sp_ram` and `ROM#@prg_ref` gain pools.
`PPU#render_pixel` alone drops by 0.62M, and the frame as a whole by 1.60M (5.0%). Startup is unchanged.
