- **bc2cpp calls implicit-self `raise` and `__id__` directly** in the wio closed
  world. Both are audited against the mruby sources on every compile (a changed
  body, a second registration of the name or a Ruby definition of it withdraws
  the row); `raise` with one or two arguments replays `mrb_f_raise` on
  `mrb_make_exception` + `mrb_exc_raise`, and a bare `raise`, a third argument
  or `cause:` keep their send. See `docs/adr/0274-bc2cpp-direct-kernel-and-parameter-natives.md`
  and `scripts/bc2cpp_direct_natives_check.rb`.
