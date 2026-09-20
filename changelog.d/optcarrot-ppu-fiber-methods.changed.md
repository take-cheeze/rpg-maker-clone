- Compile optcarrot CPU and PPU methods around Fiber boundaries while keeping
  the emulator entry path, Fiber creation, resume bridges, main loop, and yield
  points interpreted.
