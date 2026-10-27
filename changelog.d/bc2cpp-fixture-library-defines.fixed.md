- **bc2cpp fixtures are compiled with the defines of the libmruby they link.**
  The full-core library is built with `-DMRB_USE_BIGINT` and the other gem
  defines, but the fixture C++ was not. The bigint arms of the numeric slow
  path were compiled out, so a bigint receiver of `>>`, `/`, `*`, `^`, ...
  raised `closed-world proof violated: Integer#>> was proven undefined` in
  compiled fixtures only. `Bc2cppFixtureRuntime.library_defines` now reads
  `lib/libmruby.flags.mak` (`scripts/bc2cpp/bigint_slow_arms_check.rb`).
