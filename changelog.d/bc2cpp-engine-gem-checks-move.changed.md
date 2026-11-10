- The 29 bc2cpp checks that read the engine gems (`mruby-lcf`, `mruby-rgss`, `mruby-rpg2k`) now live here, in
  `scripts/bc2cpp-rpg/`, and the `bc2cpp-build` job runs the 18 fixture checks among them. They moved from nfcxx's
  `bc2cpp/scripts/bc2cpp/`, which keeps the compiler's own checks. The registry (`scripts/ci/check_registry.rb`) finds them
  there.
