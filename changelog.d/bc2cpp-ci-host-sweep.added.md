- **CI plays the closed bc2cpp build.** A new `bc2cpp-sweep` job, alongside
  `bc2cpp-build`, builds the closed world plain and in verify mode
  (`BC2CPP_UNREGISTERED_VERIFY=1`) and runs `scripts/bc2cpp/host_sweep.bash`
  on each: Nepheshel's New Game, a battle, the menu, save and load, and every
  map, headless. A registration the closed list should not have left out, or a
  stubbed mrblib body that runs, now fails the `bc2cpp` check instead of
  surfacing on a device.
