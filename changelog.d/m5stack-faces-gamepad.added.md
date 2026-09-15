- **M5Stack Core: FACES kit Gamepad Face support**: `mruby-rgss/src/m5stack.cxx`
  now polls the M5Stack FACES kit's optional Gamepad Face ("Game Face") over
  I2C (address 0x08, protocol verified directly against the module's own real
  MEGA328 firmware), folding its D-pad and A/B into the existing button
  bitmask and its Select/Start onto the spare RPG2003 Numbers ids (mirroring
  the PSP port's own spare-button convention). The QEMU emulator gained a
  matching downstream I2C device
  (`app/m5stack/qemu/patches/m5stack-gamepad.patch`) that can simulate a held
  button combination via `M5STACK_GAMEPAD_STATE`
  (`scripts/m5stack_qemu_boot.bash`) -- the first *input* injection this
  emulator supports, alongside the existing display output support. CI's
  `m5stack-qemu` job now verifies a simulated Gamepad Face press reaches the
  firmware's own status line end to end. Also fixes two latent bugs in
  `app/m5stack/src/main.cxx`'s demo (a too-short key-name table and an
  undefined-behavior mask/shift pair) that the new reachable button bits
  exposed. See `docs/adr/0157-m5stack-core-qemu-emulator.md`'s "Status,
  gamepad support".
