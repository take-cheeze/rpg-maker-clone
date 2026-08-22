- Fixed two real bugs in the vendored `mruby-marshal` gem: `Marshal.dump`
  called a custom `marshal_dump` with a stray argument instead of the zero
  arguments real Ruby's protocol defines, and `Marshal.load` called a custom
  `marshal_load` as a class factory method instead of allocating an instance
  and calling the real instance-level protocol on it. Found because a real
  VX Ace game's own `Game_Interpreter` defines both the standard way to
  snapshot its state for a battle. Since this project doesn't control this
  gem's upstream remote, the fix ships as
  `patches/mruby-marshal-dump-load-protocol.patch`, applied idempotently at
  build time by `scripts/apply_mruby_patch.bash`.
