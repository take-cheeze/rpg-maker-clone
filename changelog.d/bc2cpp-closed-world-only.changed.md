- bc2cpp is now closed-world only (ADR 0466). `RPGMAKER_BC2CPP=1` adds the
  compiled gems to the RPG2000/2003-only psp/wio/maix builds; the desktop, wasm
  and Android builds load Ruby at runtime and stay the plain mruby build.
  `BC2CPP_CLOSED_WORLD` and `RPGMAKER_BC2CPP_CLOSED_WORLD_HOST` are gone, and
  bc2cpp.rb refuses a run without its build, gem list and outside sources. The
  `bc2cpp` CI gate builds the closed-world maix library.
