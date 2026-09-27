bc2cpp: skip the hand-written duplicate registrations in a full build

Every hand-written `mrb_define_(private_|class_)?method` in the three
`*-compiled/src/register.cxx` files names a method that the
`bc2cpp_register_owner_methods(M)` call above it already installs. Measured on
the real hot-only wio closed world, by matching each call's callee against the
run's own "compiled entry points" listing:

  mruby-lcf-compiled    39 registrations,  39 duplicates,  0 orphans
  mruby-rgss-compiled   96 registrations,  96 duplicates,  0 orphans
  mruby-rpg2k-compiled 1240 registrations, 1240 duplicates, 0 orphans

So a FULL build registers each of those 1375 methods twice. mruby's
`mrb_define_method` overwrites, which is why this has been harmless (and why
ADR 0139 already notes the generated registration is written to be idempotent),
but it is 1375 redundant call sites and a second place to keep in sync.

They cannot simply be deleted, because a HOT-ONLY build does not compile 1229
of the 1375 callees at all -- measured the same way against the hot-only
listing. The generated call then installs a no-op `bc2cpp_hot_only_excluded`
overload for an excluded name, which does not reference the real `_impl`, so
the hand-written calls are what keep those symbols alive. Removing them
unconditionally is a link error on every excluded method.

The block is therefore guarded, and the guard reads a macro the generated file
emits on the hot-only path only, next to the no-op overloads that exist only
there:

  #define BC2CPP_HOT_ONLY_STUBS 1
  struct bc2cpp_hot_only_excluded {};
  static inline void mrb_define_method(..., bc2cpp_hot_only_excluded, ...) {}

register.cxx already #includes that generated file, so no second build flag is
needed and the two modes cannot drift. Verified by preprocessing the rpg2k
register.cxx against each generated file: 1663 registrations survive in a full
build, 115 do in a hot-only build. All three register.cxx compile in both modes.

No flash is saved either way -- `mrb_define_method` interns a symbol and fills a
method-table entry at init, which is heap, not bytes. The point is removing a
duplicated source of truth, not size.
