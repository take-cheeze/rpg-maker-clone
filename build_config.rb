# Gems shared by every build variant (the actual game libraries).
def rpg_maker_gems(conf)
  conf.gem core: 'mruby-array-ext'
  conf.gem core: 'mruby-hash-ext'
  conf.gem core: 'mruby-io'
  conf.gem core: 'mruby-print'

  conf.gem "#{MRUBY_ROOT}/../mruby-stringio"
  conf.gem "#{MRUBY_ROOT}/../mruby-marshal"
  conf.gem "#{MRUBY_ROOT}/../mruby-onig-regexp" do
    bundle_onigmo
  end

  conf.gem "#{MRUBY_ROOT}/../../mruby-lcf"
  conf.gem "#{MRUBY_ROOT}/../../mruby-rgss"
  conf.gem "#{MRUBY_ROOT}/../../mruby-rpg2k"
  conf.gem "#{MRUBY_ROOT}/../../mruby-rpgxp"
end

# When targeting Emscripten the host build only exists to produce the `mrbc`
# bytecode compiler (which must run natively during the cross build), while the
# actual libmruby.a is produced by the `emscripten` cross build below.
emscripten = ENV['MRUBY_TARGET'] == 'emscripten'

MRuby::Build.new do |conf|
  toolchain :gcc

  enable_debug

  if emscripten
    # Force native host compilers so `mrbc` runs on the build machine even when
    # CMake hands us emcc/em++ via CC/CXX.
    conf.cc.command = ENV['HOST_CC'] || 'cc'
    conf.cxx.command = ENV['HOST_CXX'] || 'c++'
    conf.linker.command = ENV['HOST_CXX'] || 'c++'

    conf.gem core: 'mruby-bin-mrbc'
    rpg_maker_gems(conf)

    # The host mrbc pre-interns symbols (presym) while compiling the target's
    # Ruby sources, baking symbol *indices* into the bytecode. The host and
    # emscripten builds pull slightly different dependency gems, so their presym
    # tables diverge and the target mruby then reads bytecode symbols at the
    # wrong indices and corrupts its init. Disabling presym makes the bytecode
    # reference symbols by name, which is portable across the two builds.
    conf.disable_presym
  else
    enable_test

    [cc, cxx].each do |t|
      t.flags = t.flags.flatten.delete_if { |v| v == "-O0" }
    end

    rpg_maker_gems(conf)
  end
end

if emscripten
  MRuby::CrossBuild.new('emscripten') do |conf|
    toolchain :clang

    conf.cc.command = 'emcc'
    conf.cxx.command = 'em++'
    conf.linker.command = 'emcc'
    conf.archiver.command = 'emar'

    # autotools inside mruby-onig-regexp needs a `--host` triplet that its
    # (old) config.sub recognizes to enter cross-compilation mode. onigmo's
    # config.sub does not know the real `*-emscripten` system, so use the
    # closest triplet it accepts; it keeps the 32-bit wasm word size and only
    # forces cross-compile mode (the actual compiler is still emcc).
    conf.host_target = 'wasm32-unknown-linux'

    enable_debug

    # Must match the host build so the (name-based) bytecode mrbc emits is
    # loadable here; see the note on the host build above.
    conf.disable_presym

    [conf.cc, conf.cxx].each do |t|
      t.flags = t.flags.flatten.delete_if { |v| v == "-O0" }
      # Raise the maximum string length to 4 MiB. On native platforms mruby
      # defaults MRB_STR_LENGTH_MAX to 0 (unlimited), but Emscripten defines
      # none of __linux__/__APPLE__/__*BSD__, so string.c falls through to the
      # 1 MiB cap and rejects larger strings with "string too long". Game data
      # (maps, images loaded as strings) can exceed 1 MiB, so bump it to 4 MiB.
      t.defines << 'MRB_STR_LENGTH_MAX=4194304'
    end

    rpg_maker_gems(conf)
  end
end
