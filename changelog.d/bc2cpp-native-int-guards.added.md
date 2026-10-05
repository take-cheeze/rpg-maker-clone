- bc2cpp now asks the Fixnum proof before emitting the Integer tag test of a
  `NATIVE_DIRECT_EXACT` arm's `:int` argument, as the `Bitmap.new` and
  `NATIVE_EXACT_DIRECT` paths already did. A proven argument loses its runtime test
  and with it the arm's only remaining by-name dispatch: 9 fewer cached sends
  (`z=` 6, `x=` 2, `flash` 1) in the wio closed world, all removals. The
  class-tested `NATIVE_DIRECT` arms are unchanged — they run only where no
  receiver proof exists. `BC2CPP_NATIVE_INT_GUARDS=0` is the control. See ADR 0358.
