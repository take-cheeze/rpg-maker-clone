# One-compare Array bound tests (UNSIGNED_INDEX)

Generated code reads an Array element through `bc2cpp_ary_entry`, the same-file copy of `mrb_ary_entry`
([always inlined](bc2cpp-hot-inline.md)). The copy used to follow the library body line for line:

```cpp
mrb_int len = ARY_LEN(a);        // tests the embed flag
if (n < 0) n += len;
if (n < 0 || len <= n) return mrb_nil_value();
return ARY_PTR(a)[n];            // tests the embed flag again
```

GCC kept both embed-flag tests and the signed adjustment, about 17 instructions for a read that is almost always
in range. The helper now reads the flag once and puts the in-range read first:

```cpp
if (ARY_EMBED_P(a)) { p = ARY_EMBED_PTR(a); len = ARY_EMBED_LEN(a); }
else                { p = a->as.heap.ptr;   len = a->as.heap.len;   }
if (mrb_likely((mrb_uint)n < len)) return p[n];
mrb_uint from_end = (mrb_uint)n + len;
return from_end < len ? p[from_end] : mrb_nil_value();
```

## Why the result is the same for every index

`len` is at most `MRB_INT_MAX`, and `w` is the width of `mrb_uint`.

- `0 <= n < len`: the unsigned compare holds and the read is `p[n]`, as before.
- `n >= len`: the compare fails. `n + len` is less than `2 * MRB_INT_MAX + 1`, so it does not wrap and stays at or
  past `len`. The result is `nil`, as before.
- `-len <= n < 0`: `(mrb_uint)n` is at least `2^w - len`, so the first compare fails. Adding `len` wraps to
  `len + n`, which is in `[0, len)`, and the read is `p[len + n]`. This is the library's `n += len`.
- `n < -len`: the sum wraps to `2^w - (-n - len)`. Because `-n <= 2^(w-1)`, this is at least `2^(w-1)`, which
  is greater than `len`. The result is `nil`, as before.

The argument holds for any word width `w` (a 32-bit `mrb_int` on the cross targets as well).

## The fronts and the write

- `bc2cpp_getidx`'s inline front and the GETIDX arm for a receiver known to be an Array test `mrb_fixnum_p(key)`
  instead of `mrb_integer_p(key)`. That drops the heap-Integer unboxing branch from the hot path. A heap Integer
  key still reaches the Array body: the front's outlined `bc2cpp_getidx_slow` keeps its `mrb_integer_p` arm, and
  the static arm's else is `[]` itself (INTEGER_TAG_ELSE or the by-name send). Such a key is outside every fixnum
  range, and `Array#[]` raises `RangeError` for it as before.
- `bc2cpp_ary_set` stores only when `(mrb_uint)n < len` and the Array is neither shared nor frozen. A negative index
  now calls `mrb_ary_set`, which counts from the end, raises `IndexError` or grows the Array exactly as before.

A site whose index is proven Integer (PROVEN_INDEX) keeps `mrb_integer(...)` and is otherwise unchanged.

## Check

`MRBC=path/to/mrbc ruby scripts/bc2cpp/unsigned_index_check.rb` checks the emitted helper text: one embed test,
the unsigned compare, no signed adjustment, the in-range-only store, and the fixnum fronts. It then reads every
index class on embedded, heap, shared and empty Arrays. The classes are in range, from the end, exactly `-len`,
past either end, the fixnum extremes, a heap Integer and a Float key. It also writes in range, from the end,
past the end, before the start and on a frozen Array. Interpreted and compiled runs must print the same.

## Measurement

These figures come from the optcarrot probe (Lan_Master, release `-O3`, callgrind) at master `6bfa22db`.
Instructions per frame are the difference between runs of 21 and 1 frames, divided by 20. Checksum `59662` at
180 frames is unchanged.

| Build | Instructions per frame | 1-frame run |
| --- | ---: | ---: |
| master | 29,828,690 | 1,488.44M |
| UNSIGNED_INDEX | 26,637,478 | 1,449.61M |

That is 10.7% of the frame. Most of it is the per-pixel reads in `PPU#render_pixel` (1.58M a frame, including
the Integer unboxing that `boxing_word.h` inlined there), followed by `CPU#fetch` (0.54M), the sprite evaluation
and the tile fetches.
