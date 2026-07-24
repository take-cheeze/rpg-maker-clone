MRuby::Gem::Specification.new('mruby-mvjs') do |spec|
  spec.license = 'MIT'
  spec.author = 'take-cheeze'
  spec.summary = 'RPG Maker MV support via an embedded JavaScript (quickjs-ng) runtime'

  # The game's own JavaScript draws and takes input through the shared engine
  # layer, and reads its data/asset files through mruby-io.
  add_dependency 'mruby-rgss'
  add_dependency 'mruby-io'

  # The embedded JavaScript engine (quickjs-ng, vendored at 3rd/quickjs). The
  # header is needed to compile src/mvjs.cxx in every build (native and wasm);
  # the static `qjs` library — built by the top-level CMake, which also links it
  # into the main executable — is linked into the mruby test binary here, along
  # with the C libraries quickjs depends on (libm and pthreads).
  cxx.include_paths << "#{dir}/../3rd/quickjs"
  linker.library_paths << "#{ENV["PROJECT_BUILD_DIR"]}/3rd/quickjs"
  linker.libraries << "qjs" << "m" << "pthread"
end
