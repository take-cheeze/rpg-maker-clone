- **PSP: the main-thread stack is now an explicit, verified size (ADR 0047's
  P5).** `app/psp/main.cxx` sets `PSP_MAIN_THREAD_STACK_SIZE_KB(256)` rather
  than relying on pspsdk's implicit default, and the `RPG2K_PSP_BRINGUP`
  heartbeat now carries two new fields, `stack_free` and `stack_used_max`.
  The former is `sceKernelGetThreadStackFreeSize`'s scan of the untouched
  (still 0xFF-filled) low end of the stack; because a down-growing stack never
  returns used bytes to 0xFF, any sample is already the high-water mark of how
  deep the interpreter has recursed, and `stack_used_max` tracks the maximum
  seen across the run. The 256 KB figure keeps the size that already runs the
  real RPG2k scene tree, but the log now shows how much of it a real game
  actually reaches, so a deeper-recursing title is caught by the numbers
  before it crashes instead of by a guessed constant.
