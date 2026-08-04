MRuby::Gem::Specification.new('mruby-mvjs') do |spec|
  spec.license = 'MIT'
  spec.author = 'take-cheeze'
  spec.summary = 'RPG Maker MV support via an embedded JavaScript (quickjs-ng) runtime'

  # The game's own JavaScript draws and takes input through the shared engine
  # layer, and reads its data/asset files through mruby-io.
  add_dependency 'mruby-rgss'
  add_dependency 'mruby-io'
  # Ruby-side maker logic uses Array#- (MZ.runnable_scripts filters the engine
  # script list); it lives in the core mruby-array-ext gem, not mruby's base
  # Array. Declare the dependency so the gem — and its own test build — always
  # pull it in, rather than relying on the top-level build_config or hand-rolling
  # the difference. (mruby core omits several stdlib methods into *-ext gems; the
  # rule is to depend on the providing core gem, see AGENTS.md.)
  add_dependency 'mruby-array-ext'

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

  # OSMesa (off-screen software Mesa) + GLES2 back the MZ WebGL renderer
  # (src/mvgl.cxx, milestone M6.3): OSMesa renders into a CPU RGBA buffer with no
  # GPU/display, matching the software LVGL pipeline. This is optional — mvgl.cxx
  # stubs itself out where the OSMesa headers are absent (Emscripten's browser
  # WebGL; the nix build until OSMesa is packaged) — so only link the libraries
  # when this build actually has the header. Probe with the configured compiler
  # so the check honours the same include paths the build uses (apt's
  # /usr/include, a nix buildInput, etc.); provided by libosmesa6-dev /
  # libgles2-mesa-dev on apt.
  if ENV["MRUBY_TARGET"] != "emscripten"
    have_osmesa =
      begin
        system("echo '#include <GL/osmesa.h>' | #{cc.command} -E -x c - " \
               ">/dev/null 2>&1")
      rescue StandardError
        false
      end
    linker.libraries << "OSMesa" << "GLESv2" if have_osmesa
  end
end
