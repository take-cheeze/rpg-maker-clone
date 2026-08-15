- **The mruby build's CMake glue is no longer duplicated.** Root
  `CMakeLists.txt` (desktop/wasm) and `app/psp/CMakeLists.txt` (the PSP EBOOT)
  each drove `libmruby.a`'s rake-based build (`build_config.rb`) with their
  own near-identical copy of the same custom command, gem-source glob and
  mgem-list symlink dance. Factored the shared parts into
  `cmake/build-mruby.cmake`'s `rpg2k_add_mruby()`, parameterized by the mruby
  build's target name, its local gem list (root includes `mruby-mvjs`, PSP
  does not) and any extra rake options (`MRUBY_TARGET=`, host `CC=`/`CXX=`
  overrides, ...). Both call sites now differ only in those arguments. No
  behavior change: verified with a scratch CMake project reproducing each
  call site that the generated `mruby_build` custom command and rake
  invocation are unchanged.
