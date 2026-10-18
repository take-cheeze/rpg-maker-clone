# 0490. bc2cpp: persist literal native constants (Color, Rect, Tone) statically

Date: 2026-10-18

## Status

Proposed

## Context

ADR 0468 and PR #2362 let bc2cpp prove that a single-assignment constant
initialized by `Klass.new(...)` allocates exactly the native class `Klass`
names (`infer_constructed_constant_classes` / `native_constructed_class` in
`tools/bc2cpp/dispatch_targets.rb`, gated by `native_class_unshadowed?` and
`class_new_is_stock?`). The receiver fact is then used for dispatch.

The value itself is still built at runtime. For example
`mruby-rpg2k/mrblib/scene/map_viewer.rb` has
`BLOCKED_COLOR = Color.new(160, 48, 48, 255)`, and the program runs that
`SETCONST` once at startup. The open question was whether the object can be
emitted as static data, so the constant needs no construction at all.

Facts from this checkout that bound the design:

- `Color`, `Tone` and `Rect` are C++ structs of plain numbers
  (`mruby-rgss/src/lib.cxx`: `Color` is four `double`s, `Tone` four `double`s,
  `Rect` integers). Their constructors clamp with `clamp255` and
  `clamp_signed255`. Those clamps are pure functions of the literal, so the
  value a literal argument produces is computable at codegen time.
- The mrb object is not a plain struct. `DataType<T>::make` (lib.cxx) wraps the
  value in an `RData` whose pointer is a `std::shared_ptr<T>` with an
  `mrb_malloc`/`mrb_free` deleter, so the control block is heap-allocated.
- The `RClass*` in the `RData` header comes from the gem-init accessors
  `rgss::native_color_class()` and friends (`g_native_*_class`). It is known
  only after `mrb_define_class_under` has run, not at codegen time.
- The GC owns `RData` objects. Sweep frees them through their `dfree`, and
  mark walks their ivars. A static `RObject` is not on the heap list, so its
  lifetime and mark state would need an explicit rule. The `3rd/mruby` submodule
  is not checked out in this worktree, so the mark and sweep code could not be
  read here to confirm that rule.
- Data objects can carry ivar slots (`codegen_emit.rb`, `mrb_data_ivar` tables),
  so a persisted object must prove it never gets an ivar that points to a heap
  object.
- The values are mutable (`Color#red=`, `#set`), and the constants are compared
  by identity (`color.equal?(BLOCKED_COLOR)` in `map_viewer.rb`). Any static
  object must be the one object the constant names for the whole process.

## Feasibility

The value representation is exact. Doubles hold the clamped integer and float
literals, and the clamps can be reproduced in codegen. A literal-only argument
list is easy to recognise with the existing reaching-definition walk.

The blocker is the object, not the value:

1. A static `RData` needs a `shared_ptr` whose control block is in static
   storage. The standard library does not allow that without a dynamic
   allocation, so the object would still be constructed at program start.
2. The `RClass*` must be patched into the static header during gem init. That
   is a new init-time fixup that no generated code does today.
3. The GC has to be taught that a static, non-heap `RData` is never swept and
   that its children are marked. That is a runtime change in mruby integration,
   and it cannot be checked without the mruby sources.
4. Each persisted object needs its own proof that no ivar is set on it. That
   proof does not exist today.

Items 1 to 3 are new runtime structures across the C++ runtime. That is past
the "small, sound" bar in the task, so no code is changed.

## Decision

Do not persist these objects statically. Keep `Klass.new` at startup for these
three literal constants. The bc2cpp receiver fact from ADR 0468 stays as it is.

Possible follow-up that is smaller and sound: at gem init, build the literal
value with the existing direct constructors (`rgss::color_new_direct` and the
two others) and bind it to the constant with `SETCONST`. This removes the
`Class#new` dispatch but keeps one allocation per constant, and it does not
need GC, static storage or ivar proofs. Its gain is small, so it should be
measured before anyone builds it.

## Consequences

- No behavior, generated code or check changes. The `BLOCKED_COLOR` family keeps
  its runtime `Class#new`.
- Blocking question for the owner: is one init-time construction per constant
  (the follow-up above) acceptable, or is the goal strictly zero construction?
  Zero construction requires static `RData` objects and the GC rule in item 3,
  which needs the mruby sources to be checked out and reviewed before any code.
- If static persistence is wanted later, the first step is a check that reads
  the mruby mark and sweep rules for non-heap objects, then a fixture that
  compares the persisted value with what `Class#new` produces for each of the
  three classes.
