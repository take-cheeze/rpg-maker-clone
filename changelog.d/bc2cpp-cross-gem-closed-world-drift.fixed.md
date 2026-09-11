- Fixed a real, previously-unenforced drift risk in the opt-in
  (`RPGMAKER_BC2CPP=1`) AOT compiler's cross-gem devirtualization
  mechanism: the whole-program `closed_world_srcs` list each of
  `mruby-lcf-compiled`'s/`mruby-rpg2k-compiled`'s/`mruby-rgss-compiled`'s
  own `mrbgem.rake` feeds into `bc2cpp.rb` (so each gem's own MONO/POLY
  registry sees the same whole program) was three separately hand-typed
  `Dir[...]` literals, confirmed byte-identical today but with nothing
  enforcing that -- unlike the owners list and native-method source set,
  both already centralized in `tools/bc2cpp/compiled_gems.rb` for
  exactly this reason. A future edit to just one or two of the three
  files would silently reintroduce the soundness gap
  `OTHER_OWNERS`/`OTHER_DECLS_HEADER` exists to close, with no build
  error at all. Extracted a new `closed_world_mrblib_srcs` helper into
  `compiled_gems.rb` and pointed all three `mrbgem.rake` files at it;
  confirmed byte-identical generated output before/after across all
  three gems, so zero behavioral change today. Also fixed a real
  documentation-accuracy gap found by the same round's dedicated
  cross-gem-devirtualization-soundness sweep:
  `RPG2k::Scene::DebugMenu#open_map_viewer`'s own "stays interpreted due
  to a `rescue` clause" comment (in `docs/adr/0139`,
  `tools/bc2cpp/compiled_gems.rb`, and `mruby-rpg2k-compiled/src/
  register.cxx`) named only one of its two independent gaps -- its
  `if`/`else` branches each hit a different, unrelated unsupported-opcode
  shape (`RESCUE`/`RAISEIF`/`EXCEPT` in one, a keyword-argument call site
  in the other). No new live miscompilation bug found this round: a
  cross-gem `LCF::Array1D#delete` call from three `mruby-rpg2k-compiled`
  methods (including this tool's own long-standing README example,
  `Game::Actor#forget_skill`) was re-confirmed to correctly compile to
  ordinary dynamic dispatch, not an unsound direct call, and the
  `MRB_SET_INSTANCE_TT` diagnostic was re-confirmed clean across all 59
  current owners. See `docs/adr/0139-bc2cpp-lcf-file-aot-compile.md`'s
  own follow-up.
