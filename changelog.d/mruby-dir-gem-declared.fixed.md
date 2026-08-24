- **Android (all cross targets):** boot died in `mrb_open()` with
  `NameError: uninitialized constant Dir`. mruby 4.0 moved `Dir` out of
  `mruby-io` into its own core gem (`mruby-dir` + a HAL backend), and nothing
  in the shared gem list declared it — the desktop binary only had it because
  the host build's `enable_test` leaked `mruby-rgss`'s test-suite dependency
  into the game link, something cross builds never do. `rpg_maker_gems` now
  declares `mruby-dir` explicitly.
