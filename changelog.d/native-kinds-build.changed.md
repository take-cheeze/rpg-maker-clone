- **bc2cpp:** the native return-kind table is generated from the closed build
  (`scripts/bc2cpp/native_fn_kinds.rb`), so clang sees the presym IDs and the
  RGSS `shinonome.hxx` header. `closed_build.bash` writes that header.
