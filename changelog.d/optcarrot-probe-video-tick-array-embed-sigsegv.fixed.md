- Fix a CI-reproducible SIGSEGV in the Optcarrot bc2cpp probe's
  `compiled_run.rb`: compiling `Optcarrot::CPU`/`NES`/`Video`/`APU`
  (previously "confirmed safe") crashes the real, Fiber-driven 180-frame
  `nes.run` loop, which shorter local smoke checks never exercised long
  enough to hit. Bisected down to `Optcarrot::Video#tick` alone, with
  nothing else compiled: it segfaults on its 4th call, every time, exactly
  when its `@times` Array ivar outgrows mruby's 3-element embedded-array
  storage on this word-boxed 64-bit build -- bc2cpp's generated `ARY_LEN`/
  `ARY_PTR` codegen for `Array#last` reads a stale cached pointer from one
  `mrb_val_union` call while a different call for the identical value,
  moments later, correctly returns the array's real pointer. `CPU`, `NES`,
  `Video`, and `APU` are excluded from `ONLY_OWNERS` again, alongside the
  already-excluded `PPU`, until that bc2cpp code-generation defect is fixed;
  the probe now compiles only `Optcarrot::Config`/`Optcarrot::Opt` plus the
  `Optcarrot::ROM` setup methods, which the full 180-frame run completes
  cleanly with a matching checksum on all three runtimes, repeatedly. See
  `tools/optcarrot_probe/README.md`'s "Compiled runtime check" section.
