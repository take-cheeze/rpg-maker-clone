- **The psp and maix builds also leave unreachable core methods out of mruby's
  ROM method tables.** They use the same list as the closed build
  (`tools/bc2cpp/static_dispatch_core_excluded.rb`). Both builds are
  single-format and interpreted, so everything they can run is inside the world
  the proof reads. On maix the firmware's section GC also drops the excluded C
  functions; on psp only the table rows go. wio, desktop, wasm, android, and
  psp/maix built with `RPGMAKER_BC2CPP=1` keep their full tables. See "Device
  builds" in `docs/bc2cpp-unregistered-methods.md`.
