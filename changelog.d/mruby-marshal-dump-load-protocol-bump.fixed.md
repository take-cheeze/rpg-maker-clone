- **Bumped the vendored `mruby-marshal` submodule** to pick up a fix for
  `Marshal.dump`/`Marshal.load`'s calling convention with a custom
  `marshal_dump`/`marshal_load` pair, found via a real RPG Maker VX Ace game
  whose `Game_Interpreter` defines one. `Marshal.dump` passed a stray extra
  argument to `marshal_dump` (real Ruby's protocol takes none), raising
  `ArgumentError`; `Marshal.load` called `marshal_load` as a class factory
  method instead of allocating a new instance and restoring it in place via
  the instance method real Ruby's protocol defines, raising `NoMethodError`
  once the first bug was worked around. Both now match real Ruby.
