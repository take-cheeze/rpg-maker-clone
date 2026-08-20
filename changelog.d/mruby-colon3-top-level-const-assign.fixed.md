- Fixed a real bug in the vendored mruby compiler: `::Const = value`, written
  from inside a nested module or class body, silently defined the constant on
  the *lexically enclosing* module instead of at the top level -- no
  exception, just the wrong owner (`gen_colon3_assign` emitted `OP_SETCONST`,
  which ignores the pushed base, instead of `OP_SETMCNST`). Found because a
  real RPG Maker VX Ace game's bundled add-on relies on exactly this pattern
  to publish its own top-level API and never finished setting up. Since this
  project doesn't control the `3rd/mruby` submodule's upstream remote, the
  fix ships as `patches/mruby-colon3-assign-setmcnst.patch`, applied
  idempotently at build time by `scripts/apply_mruby_patch.bash`.
