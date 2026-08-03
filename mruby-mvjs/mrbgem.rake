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
  # stb_image.h for PNG decoding in the Image loader (mvcanvas.cxx). The
  # implementation (STB_IMAGE_IMPLEMENTATION) is compiled by mruby-rgss, so only
  # the header is needed here; the decode symbols resolve at link.
  cxx.include_paths << "#{dir}/../3rd/stb"
  # rgss_bitmap.hxx (repo include/) for the on-screen present path, which copies
  # the MV canvas into an RGSS::Bitmap. The accessor is defined in mruby-rgss.
  cxx.include_paths << "#{dir}/../include"
  linker.library_paths << "#{ENV["PROJECT_BUILD_DIR"]}/3rd/quickjs"
  linker.libraries << "qjs" << "m" << "pthread"
end
