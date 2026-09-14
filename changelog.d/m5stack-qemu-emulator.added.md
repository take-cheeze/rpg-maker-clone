- **M5Stack Core emulator (QEMU, not Renode)**: `scripts/m5stack_qemu_boot.bash`
  boots the M5Stack Core firmware under Espressif's own QEMU fork -- Renode
  ships no usable ESP32/Xtensa platform to build on, unlike the Wio
  Terminal's Renode setup, so this port uses the same QEMU binary
  `idf.py qemu` does instead. CI's `m5stack-qemu` job verifies the real CPU
  reaches this project's own compiled second-stage bootloader. A real,
  isolated, currently-open gap in `framework-arduinoespressif32`'s vendored
  ESP-IDF v4.4.7 (not this project's firmware, and not a general QEMU
  limitation -- confirmed by a controlled comparison against a plain
  ESP-IDF 6.1.0 build) keeps it from reaching `setup()` yet. See
  `docs/adr/0157-m5stack-core-qemu-emulator.md`.
