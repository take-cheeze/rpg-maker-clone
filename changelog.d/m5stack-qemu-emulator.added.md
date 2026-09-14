- **M5Stack Core emulator (QEMU, not Renode)**: `scripts/m5stack_qemu_boot.bash`
  boots the M5Stack Core firmware under Espressif's own QEMU fork -- Renode
  ships no usable ESP32/Xtensa platform to build on, unlike the Wio
  Terminal's Renode setup, so this port uses the same QEMU binary
  `idf.py qemu` does instead. It reaches `setup()` and `loop()` for real
  (the firmware's own display/button HAL runs, verified over the real
  UART): building Arduino as an ESP-IDF component
  (`framework = arduino, espidf`, `app/m5stack`'s own standalone
  `platformio.ini`) sidesteps a real assert in the precompiled Arduino
  libs' own SPI flash re-probe under this exact QEMU release. CI's
  `m5stack-qemu` job asserts the same. See
  `docs/adr/0157-m5stack-core-qemu-emulator.md`.
