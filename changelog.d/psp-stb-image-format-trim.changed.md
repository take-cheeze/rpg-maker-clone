- **PSP/desktop/wasm/wio: stb_image no longer compiles in decoders the engine
  never calls.** The asset search this engine performs only ever tries
  `.png`, `.jpg`/`.jpeg`, `.bmp` (via stb) and `.xyz` (a custom decoder, not
  stb's) — `mruby-rgss/src/lib.cxx` now defines `STBI_NO_GIF`/`STBI_NO_PSD`/
  `STBI_NO_TGA`/`STBI_NO_HDR`/`STBI_NO_PIC`/`STBI_NO_PNM` before including
  `stb_image.h`, so those six unreachable format decoders are no longer
  linked into any target. Measured on a host build: `lib.o`'s `.text` shrinks
  by ~37 KB. The PSP cross-build also adds `STBI_NO_STDIO`, dropping stb's
  `FILE*`-based `stbi_load(path, ...)` path — dead code there since that
  build excludes `mruby-mvjs` (the only caller) and `mruby-rgss`'s own
  loader always decodes via `stbi_load_from_memory`. On the PSP every
  PT_LOAD segment of the EBOOT is mapped into RAM at launch, so this is live
  RAM there, not just file size; desktop/wasm/wio shrink by the same unused
  decoders for free. See `docs/adr/0047-psp-memory-budget.md`.
