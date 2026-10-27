# Always-inlined Array element helpers (HOT_INLINE)

Generated code reads and writes Array elements through four small same-file helpers:

- `bc2cpp_ary_entry`, the copy of `mrb_ary_entry` ([ARY_ENTRY_INLINE](../tools/bc2cpp/codegen_emit.rb));
- `bc2cpp_ary_push` and `bc2cpp_ary_set`, the fast paths in front of `mrb_ary_push` and `mrb_ary_set`
  ([array write inline](bc2cpp-array-write-inline.md));
- `bc2cpp_getidx`, the exact-Array front of the outlined `x[i]` chain (GETIDX_INLINE_ARRAY in
  `tools/bc2cpp/codegen_ivar_poly.rb`).

Each one is a few loads, compares and a store. They exist so that the common case costs no call, but
`static inline` is only a hint. In the optcarrot probe, GCC's `-O3` inliner kept dropping one of them from large
callers such as `PPU#render_pixel`, and which one moved whenever an unrelated change grew a caller. In one build
`render_pixel` called `bc2cpp_ary_entry` out of line once per pixel, 61,440 times a frame. In another it called
`bc2cpp_getidx` out of line instead.

The prologue of the generated file now defines `BC2CPP_HOT_INLINE`, and the four helpers carry it:

```cpp
#if defined(__GNUC__) && !defined(__OPTIMIZE_SIZE__)
#define BC2CPP_HOT_INLINE __attribute__((always_inline))
#else
#define BC2CPP_HOT_INLINE
#endif
```

A build optimized for size (`-Os`, which defines `__OPTIMIZE_SIZE__`: the Wio Terminal and RISC-V board
targets in `build_config.rb`) keeps the compiler's own choice, so its flash budget does not change.
Behaviour does not change either: each helper's body is the same.

## Check

`MRBC=path/to/mrbc ruby scripts/bc2cpp/hot_inline_check.rb` asserts that the four helpers are emitted with
the macro after its definition. It also asserts that the macro expands to `always_inline` under `-O2` and
to nothing under `-Os`. Reads, writes and pushes at in-range, negative, out-of-range and frozen positions
must print the same interpreted and compiled.

## Measurement

These figures come from the optcarrot probe (Lan_Master, release `-O3`, callgrind). Instructions per frame
are the difference between runs of 21 and 1 frames, divided by 20. Checksum `59662` at 180 frames is
unchanged. All builds were made at master `479b31ff`.

| Build | Instructions per frame | 1-frame run | `.text` |
| --- | ---: | ---: | ---: |
| master | 35,997,856 | 1,506.85M | 3,399,185 |
| master + HOT_INLINE | 35,431,234 | 1,501.88M | 3,473,261 |
| with resumable locals and ivar proof scope | 32,704,557 | 1,501.00M | 3,358,305 |
| the same + HOT_INLINE | 32,191,709 | 1,495.87M | 3,435,341 |

The gain is 1.6% of the frame in both cases. `.text` grows by about 75 KB (2.2%).
