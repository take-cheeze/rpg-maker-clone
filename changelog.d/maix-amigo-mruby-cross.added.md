- **Maix Amigo mruby cross-build**: `scripts/maix_mruby_build.bash` builds
  build_config.rb's new `maix` cross target (riscv64 `libmruby.a`, PSP-style:
  single-format RPG2k-only), and CI's `maix` job runs it alongside the
  firmware build, uploading both binaries as artifacts. See
  `app/maix/README.md`.
