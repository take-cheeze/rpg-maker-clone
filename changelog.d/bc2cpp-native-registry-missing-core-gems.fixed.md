- Fixed a real, previously-undocumented registry-soundness gap in the
  opt-in (`RPGMAKER_BC2CPP=1`) AOT compiler's whole-program native-method
  registry (`tools/bc2cpp/compiled_gems.rb`'s `core_native_srcs`):
  it mirrored only `build_config.rb`'s own *explicit* `conf.gem core:
  'mruby-xxx'` calls, missing 8 real mruby core mrbgems this project's
  own real build actually loads *transitively* -- `mruby-pack`/
  `mruby-string-ext` (direct dependencies of `mruby-lcf`/`mruby-rgss`),
  `mruby-struct`/`mruby-metaprog` (pulled in by `mruby-marshal`), and
  `mruby-binding`/`mruby-eval`/`mruby-method`/`mruby-proc-ext` (pulled in
  by `mruby-rpgxp`, always active in this project's real desktop/host
  build) -- each just as real a native-name collision risk as a
  directly-declared core gem. Also added a new `external_gem_native_srcs`
  helper for three more always-active gems that live in their own
  separate submodules entirely outside `mruby_root`
  (`mruby-marshal`/`mruby-onig-regexp`/`mruby-stringio`), wired into all
  three compiled gems' `mrbgem.rake` files alongside `core_native_srcs`.
  Scanning the real, current closed world with all 11 sources added found
  4 more real MONO->POLY flips (`:members`, `:owner`, `:parameters`,
  `:string`) -- confirmed by hand each one is a real bytecode owner's own
  `attr_reader`-installed accessor (`RPG2k::Scene::Battle#owner`,
  `LCF::EventCommand#parameters`/`#string`, `Game::Troop#members`), an
  `irep: nil` synthetic `MethodDef` `monomorphic_target` already refuses
  to treat as a direct-call target regardless of this fix -- confirmed
  not currently exploitable, and confirmed by a real, full closed-world
  regeneration of all three compiled gems' output plus the real
  `RPGMAKER_BC2CPP=1` host build: byte-identical generated `.cpp`/
  `libmruby.a` content before and after this fix. See
  `docs/adr/0139-bc2cpp-lcf-file-aot-compile.md`'s own follow-up
  (adversarial bug-hunt sweep, round 29) for the full writeup.
