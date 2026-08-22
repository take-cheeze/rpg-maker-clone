- Fixed a real gap in the vendored mruby VM: `$!` (the exception a currently
  executing `rescue` clause is handling) was never implemented -- it always
  read `nil`, even inside an active rescue, and a bare `raise` (no arguments)
  always raised a fresh, empty `RuntimeError` instead of re-raising it. Found
  because a real RPG Maker VX Ace game's bundled crash-reporter add-on relies
  on `$!.message` and a bare re-raise inside its own rescue clause, and got a
  `NoMethodError` instead of a real error report. Scoped to the call frame
  containing the `rescue` clause, using mruby's own existing frame-pop as the
  point where it goes out of scope again. Since this project doesn't control
  the `3rd/mruby` submodule's upstream remote, the fix ships as
  `patches/mruby-dollar-bang-scoped.patch`, applied idempotently at build time
  by `scripts/apply_mruby_patch.bash`.
