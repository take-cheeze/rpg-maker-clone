- **M5Stack Core: WAV audio playback**: `mruby-rgss/src/m5stack.cxx` now
  starts the Core's microSD slot (sharing the display's own SPI bus, CS on
  GPIO4) and can play a PCM WAV file off it through the built-in speaker
  (the ESP32's internal DAC on GPIO25), downmixing 8/16-bit mono or stereo
  input to 8-bit unsigned mono. `src/main.cxx`'s demo triggers this on a
  fresh press of a FACES Gamepad Face's Start button. Real-hardware-only
  for now: the WAV chunk-parsing and downmix math are verified with
  standalone host-side tests, but QEMU cannot yet exercise the SD-over-SPI
  or DAC output paths themselves (a confirmed hardware/emulation mismatch,
  not an oversight -- see `docs/adr/0157-m5stack-core-qemu-emulator.md`'s
  "Status, audio support"). Playback is a simple blocking loop, not
  I2S/DMA-driven, so it stalls the display/input loop for the file's
  duration -- documented as a real limitation, not hidden.
