- Compile optcarrot PPU methods outside the Fiber lifecycle while leaving
  `initialize`, the main loop, and yield points interpreted.
