# 122. Replace the one real RTTI use with a static name, then disable -fno-rtti for wio

Date: 2026-09-09

## Status

Accepted

## Context

ADR 120 tried `-fno-exceptions -fno-rtti` together and reverted both:
exceptions turned out load-bearing (mruby's own core), and RTTI failed on
one real, narrow use -- `mruby-rgss/src/lib.cxx`'s `DataType<T>::data_type`
used `typeid(T).name()` to fill `mrb_data_type`'s `struct_name` field for
each C-data-wrapped Ruby class (`Rect`, `Color`, `Tone`, `Table`,
`Bitmap`). Unlike exceptions, that ADR flagged this as real but *not*
load-bearing: `mruby/include/mruby/data.h` documents `struct_name` as pure
diagnostic labeling alongside the actual functional field (`dfree`, the GC
release callback) -- nothing in mruby's own runtime parses or dispatches on
it.

## Decision

Gave each of the five wrapped types its own `static constexpr const char*
kTypeName` member (`"Rect"`, `"Color"`, `"Tone"`, `"Table"`, `"Bitmap"`)
right where each struct is defined, and pointed
`DataType<T>::data_type`'s `struct_name` field at `T::kTypeName` instead of
`typeid(T).name()`. Confirmed this was the *only* `typeid`/RTTI use in the
whole gem set first (`grep -rn typeid mruby-rgss/src mruby-lcf/src
app/wio/src`, one hit, this one) and that all five wrapped types really
are the complete set (`grep DataType<` across `lib.cxx`).

Re-added `-fno-rtti` to wio's cxx flags (`build_config.rb`) -- unlike
`-fno-exceptions`, this one needed no auto-re-enable fight: mruby's gem
loader only auto-toggles exceptions (`enable_cxx_exception`, ADR 120's own
finding) when a C++ gem is present, nothing equivalent exists for RTTI.

### What was verified

- **The refactor alone, first**: rebuilt without the flag change to
  confirm `T::kTypeName` compiles and links cleanly on its own before
  touching any flags.
- **Then `-fno-rtti`**: a clean compile of every `.cxx` this gem set
  builds (`mruby-rgss/src`, `mruby-lcf/src`, `app/wio/src`) -- no other
  RTTI dependency surfaces once the one real use is gone.
- A real relink, `env:wio_rgss_boot`, on top of ADR 121's state:
  **917,512 -> 916,908**, 604 bytes. Small, as ADR 120 itself predicted
  ("a real (smaller) candidate on its own") -- reported honestly, not
  inflated. `.data`/`.bss` unchanged (37,840 bytes RAM used, 158,768
  headroom): a pure flash win, as expected (`type_info` objects and
  RTTI-related vtable slots are flash-only).
- Every other target (desktop/wasm/psp) is unaffected: `kTypeName` is a
  plain static member, valid with or without RTTI, so this is a real,
  positive side effect everywhere, not a wio-only tradeoff -- if anything,
  a small readability improvement universally: `typeid(T).name()` returns
  an implementation-mangled name (e.g. Itanium ABI's `4Rect`), while every
  target now gets the same plain `"Rect"` in any diagnostic that reads
  this field. Only the `-fno-rtti` flag itself is wio-scoped.

## Consequences

- Wio's flash overflow drops to 916,908. Combined with ADR 120's own
  documented dead end, this closes the exceptions/RTTI investigation that
  turn started: exceptions genuinely can't be removed here, RTTI now is.
- `DataType<T>` now requires each wrapped type to supply its own
  `kTypeName` -- a real (if small) contract future wrapped types must
  satisfy, enforced at compile time (a missing `kTypeName` is a hard
  compile error, not a silent fallback), unlike `typeid`, which worked for
  any type with no extra code needed.
