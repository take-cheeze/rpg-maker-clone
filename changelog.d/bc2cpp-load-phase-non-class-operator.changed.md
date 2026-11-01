- `StaticDispatchRegistrations.load_phase` now knows that a receiver built by a
  binary operator (`| & ^ + - * / % ** << >>` and the comparisons) is not a
  class or module: the closed world defines those operators natively in mruby
  core only, so an engine singleton method cannot be their target.
  `RGSS::Graphics.singleton#freeze` had been "runs at load" only because
  `(DIR_BIT[2] | …).freeze` matched it with an unknown receiver; its def now
  leaves the residual, so `RGSS::Graphics`'s body no longer enters the VM at
  boot (boot `OP_EXEC` bodies 46 -> 45, VM starts 199 -> 196, measured on the
  closed build with the VM-start counter).
