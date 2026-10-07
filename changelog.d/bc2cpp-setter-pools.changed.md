- **bc2cpp** types the receivers a setter alone writes: the arguments of every call of `x=` are joined into a class
  pool (`attr_writer`/`attr_accessor` ivars, audited native stores, the parameter of a setter with several
  definitions), and a receiver those pools prove nil or one class is called directly behind a class test whose else is
  a logged `BC2cppGuardViolation` (`CHECKED_POOL_EXACT`). 11 fewer by-name `bc2cpp_send` sites on the wio build (27
  before the singleton-definer arms of ADR 0369); `BC2CPP_SETTER_POOLS=0` restores the earlier output byte for byte.
  Covered by `scripts/bc2cpp_setter_pools_check.rb` and its mutation check (ADR 0370).
