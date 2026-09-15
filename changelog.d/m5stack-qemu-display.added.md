- **M5Stack Core emulator: real display rendering**: the QEMU boot
  (`scripts/m5stack_qemu_boot.bash`) can now capture an actual rendered
  ILI9341 frame, not just the UART log. `scripts/m5stack_qemu_build.bash`
  builds Espressif's QEMU fork from source with a new downstream patch
  (`app/m5stack/qemu/patches/m5stack-display.patch`) that adds the SPI TFT
  device upstream `espressif/qemu` lacks and fixes a real upstream SPI
  controller bug that otherwise silently corrupted every byte of every SPI
  transaction. CI's `m5stack-qemu` job now checks the actual framebuffer
  content (a real LVGL label rendered on screen), not just that the
  firmware booted. Button *input* injection remains out of reach -- see
  `app/m5stack/README.md`'s "What the emulator still cannot show" and
  `docs/adr/0157-m5stack-core-qemu-emulator.md`'s "Status, display support".
