- The Optcarrot bc2cpp probe now compiles and installs `Optcarrot::CPU`,
  `Optcarrot::PPU` (its whole Fiber-driven pixel-rendering loop included), and
  `Optcarrot::NES`, previously kept interpreted on suspicion of a Fiber-path
  crash that is no longer reproducible: all three now run the full 180-frame
  headless benchmark compiled, repeatedly, with the same checksum as the
  interpreted and CRuby runs. This does not yet produce a wall-clock win and
  slightly widens bc2cpp's relative slowdown against interpreted mruby (about
  7% to about 12.6% in a same-machine comparison) -- `CPU#run`'s data-driven
  opcode dispatch and CPU/PPU's non-embeddable ivars keep most of their
  runtime cost -- but it is a prerequisite for future ivar-embedding work and
  exercises far more of bc2cpp against a real program. See
  `tools/optcarrot_probe/README.md`'s "Compiled runtime check" section.
