- **bc2cpp base RBS** generation now puts a gem's `add_dependency` headers on
  its native include path, so `hal-wio-io` (which includes `mruby-io`'s
  `io_hal.h`) no longer shows up as `native failed` in the `bc2cpp-build` log.
  The `name_argument_flow_check.rb` fixtures also parenthesise their splat
  calls, dropping five `'*' interpreted as argument prefix` warnings.
