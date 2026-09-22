- **bc2cpp**'s bytecode-stripping mechanism (previously wio-only,
  docs/adr/0144) now also runs for the desktop and wasm builds. Real
  measured effect on a full `RPGMAKER_BC2CPP=1` host rebuild: `mruby-rpg2k`'s
  `gem_init.o` drops 7,006,008 -> 2,406,096 bytes (-65.7%), `mruby-rgss`'s
  1,059,184 -> 612,112 bytes (-42.2%), `mruby-lcf`'s 1,007,520 -> 774,312
  bytes (-23.2%) -- a combined ~5.15 MiB reduction across the three gems'
  own compiled object files. See ADR 0189.
