- Audited every one of `mruby-rgss-compiled`'s own 29 "never called"
  compiled entry points (docs/adr/0193's own diagnostic) individually
  against real evidence — none turn out to be safe to prune. Several looked
  dead only because bc2cpp.rb's own reachability scan can't see calls from
  this project's own top-level `src/*.cxx` or from the other maker engines
  it ships (`mruby-rpgxp`/`mruby-rpgvx`/`mruby-wolf`/`mruby-mv`/`mruby-mz`),
  and one (`RGSS::ErrorReport.singleton#installed?`) turned out to be
  genuinely uncalled but structurally impossible to unregister anyway — its
  owner is wired for embedding, so a generated registration call reinstalls
  it regardless of what `register.cxx` says (confirmed directly, not
  assumed). Findings and the full per-entry methodology are recorded in
  `tools/bc2cpp/rgss_confirmed_unused.rb` so a future round doesn't repeat
  the investigation. See docs/adr/0195.
