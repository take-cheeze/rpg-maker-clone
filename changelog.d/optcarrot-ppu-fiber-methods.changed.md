- Compile optcarrot CPU methods and PPU methods outside its Fiber loop while
  keeping the emulator entry path, Fiber creation, resume bridges, main loop,
  and Fiber-called PPU helpers interpreted.
