- **bc2cpp** (KERNEL_LOOP_INLINE): `loop do ... end` is inlined as a `for (;;)` over its block, so `break` is a jump
  instead of a C++ throw; StopIteration is still rescued with its result. `LCF.read_ber` broke out of its loop once per
  BER integer, about 62,000 throws while Nepheshel loads. On the headless Nepheshel host, boot to the first map went
  from 2.89 G to 0.33 G instructions, and a 1,200-frame run with a battle from 0.46 s to 0.13 s (together with the
  reopened-module constant cache). `BC2CPP_KERNEL_LOOP=0` keeps the call. See `docs/bc2cpp-kernel-loop.md`; covered
  by `scripts/bc2cpp/kernel_loop_check.rb`.
