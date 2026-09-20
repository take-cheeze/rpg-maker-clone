- Compile optcarrot PPU methods outside the Fiber lifecycle while leaving
  Fiber creation, resume bridges, the main loop, and yield points interpreted.
