MRuby::Gem::Specification.new('mruby-mvjs') do |spec|
  spec.license = 'MIT'
  spec.author = 'take-cheeze'
  spec.summary = 'RPG Maker MV support via an embedded JavaScript (quickjs-ng) runtime'

  # The game's own JavaScript draws and takes input through the shared engine
  # layer, and reads its data/asset files through mruby-io.
  add_dependency 'mruby-rgss'
  add_dependency 'mruby-io'

  # --- Milestone M2 (embedded quickjs-ng runtime) -------------------------
  # When the JavaScript host lands, vendor quickjs-ng as `3rd/quickjs` and wire
  # it in here, mirroring how mruby-lcf/mruby-rgss pull in their C++ deps:
  #
  #   cxx.include_paths << "#{dir}/../3rd/quickjs"
  #   linker.library_paths << "#{ENV["PROJECT_BUILD_DIR"]}/3rd/quickjs"
  #   linker.libraries << "quickjs"
  #
  # The C++ sources under this gem's `src/` are then picked up automatically by
  # the `foreach(g ...)` glob in CMakeLists.txt (mruby-mvjs is already listed).
end
