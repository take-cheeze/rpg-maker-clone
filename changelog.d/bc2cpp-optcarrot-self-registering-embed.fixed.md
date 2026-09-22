- `tools/optcarrot_probe/compiled_run.rb` now sets a new
  `BC2CPP_SELF_REGISTERING=1` env var when invoking `tools/bc2cpp/bc2cpp.rb`,
  telling its driver to skip `tools/bc2cpp/compiled_gems.rb`'s
  `BC2CPP_WIRED_EMBEDDINGS` allowlist for this invocation. That allowlist
  exists because the real compiled gems' hand-written `register.cxx` does
  not install every compiled entry point of an embedding class by
  construction; this probe's own `emit_register` never had that gap (it
  already installs every compiled method of any owner its own `embeds`
  diagnostic names, computed from the same diagnostic bc2cpp.rb itself
  prints), so the allowlist was pure, unnecessary dead weight here --
  previously blocking every single `Optcarrot::*` ivar from ever reaching
  a real struct field, unconditionally, since this probe was first written
  (see `tools/optcarrot_probe/README.md`'s own correction from earlier in
  this changelog for how that was found). `Optcarrot::CPU`, `ROM`, `Pad`,
  `APU`, and `APU::DMC` now get real `mrb_int`/`mrb_bool`/`mrb_sym`
  embedded struct fields instead of falling back to the ordinary dynamic
  ivar table, confirmed against the real generated code (`DATA_PTR` reads/
  writes at `CPU#run`'s own call sites, including both places it checks
  `@ppu_sync`). The full 180-frame benchmark still checksums `59662` on
  CRuby, interpreted mruby, and bc2cpp alike. No effect on the real
  project's own builds -- only this one file sets the new env var.
