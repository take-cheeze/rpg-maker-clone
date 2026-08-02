# Gems shared by every build variant (the actual game libraries).
def rpg_maker_gems(conf)
  conf.gem core: 'mruby-array-ext'
  conf.gem core: 'mruby-hash-ext'
  conf.gem core: 'mruby-io'
  # mruby 4.0 removed the mruby-print gem; Kernel#p / #print live in the core
  # now, and mruby-io (above) supplies Kernel#print / #puts / #printf.

  # mruby 4.0's compiler emits any integer literal wider than 32 bits (e.g. the
  # 0xFFFFFFFF masks in the LCF codecs) as a bignum pool entry, and its default
  # mrb_int is 32-bit, so such literals need mruby-bigint at runtime or they
  # raise "integer overflow" on load.
  conf.gem core: 'mruby-bigint'

  conf.gem "#{MRUBY_ROOT}/../mruby-stringio"
  conf.gem "#{MRUBY_ROOT}/../mruby-marshal"
  conf.gem "#{MRUBY_ROOT}/../mruby-onig-regexp" do
    bundle_onigmo
  end

  conf.gem "#{MRUBY_ROOT}/../../mruby-lcf"
  conf.gem "#{MRUBY_ROOT}/../../mruby-rgss"
  conf.gem "#{MRUBY_ROOT}/../../mruby-rpg2k"
  conf.gem "#{MRUBY_ROOT}/../../mruby-rpgxp"
  conf.gem "#{MRUBY_ROOT}/../../mruby-mvjs"
end

# When cross-compiling (Emscripten, or the Wio Terminal below) the host build
# only exists to produce the `mrbc` bytecode compiler, which must run natively
# during the cross build; the actual libmruby.a is produced by the cross build.
emscripten = ENV['MRUBY_TARGET'] == 'emscripten'
wio = ENV['MRUBY_TARGET'] == 'wio'
cross = emscripten || wio

MRuby::Build.new do |conf|
  toolchain :gcc

  enable_debug

  if cross
    # Force native host compilers so `mrbc` runs on the build machine even when
    # CMake hands us emcc/em++ via CC/CXX (emscripten). For the Wio build the
    # host toolchain is invoked natively already, so the default cc/c++ are fine.
    if emscripten
      conf.cc.command = ENV['HOST_CC'] || 'cc'
      conf.cxx.command = ENV['HOST_CXX'] || 'c++'
      conf.linker.command = ENV['HOST_CXX'] || 'c++'
    end

    conf.gem core: 'mruby-bin-mrbc'
    rpg_maker_gems(conf)
    # mruby 4.0 always enables presym (MRB_NO_PRESYM / disable_presym were
    # removed) and serializes bytecode symbols by name, so the host mrbc and the
    # cross targets (emscripten, wio) stay compatible even though their presym
    # tables differ.
  else
    enable_test

    [cc, cxx].each do |t|
      t.flags = t.flags.flatten.delete_if { |v| v == "-O0" }
    end

    rpg_maker_gems(conf)
  end
end

if wio
  # Cross build for the Wio Terminal (Seeed, ATSAMD51 / Cortex-M4F). Produces a
  # libmruby.a that the PlatformIO firmware (app/wio, platformio.ini) links. The
  # host build above supplies mrbc.
  #
  # NOTE: this is the starting point for the P1/P2 work in
  # docs/adr/0007-wio-terminal-port.md, not a finished, fitting build. The full
  # gem set (onigmo via mruby-onig-regexp, uni-algo) is expected to overrun the
  # 512 KB internal flash; trimming those (P2) is a follow-up. It is only built
  # when MRUBY_TARGET=wio, so it never affects the desktop or wasm builds.
  MRuby::CrossBuild.new('wio') do |conf|
    toolchain :gcc

    conf.cc.command = 'arm-none-eabi-gcc'
    conf.cxx.command = 'arm-none-eabi-g++'
    conf.linker.command = 'arm-none-eabi-gcc'
    conf.archiver.command = 'arm-none-eabi-ar'

    # onigmo's (old) config.sub needs a triplet it recognizes to enter
    # cross-compile mode; arm-none-eabi is such a bare-metal triple.
    conf.host_target = 'arm-none-eabi'

    enable_debug

    # Cortex-M4F with hardware single-precision FPU. Must be identical on the
    # compile and link lines so the mruby objects match the firmware's ABI.
    cpu_flags = %w[-mcpu=cortex-m4 -mthumb -mfloat-abi=hard -mfpu=fpv4-sp-d16]

    [conf.cc, conf.cxx].each do |t|
      t.flags = t.flags.flatten.delete_if { |v| v == '-O0' }
      t.flags += cpu_flags
      # Bare-metal newlib: give game data (maps/images loaded as strings) room
      # beyond the 1 MiB default cap. Actual RAM fit is a separate concern
      # handled by the streaming rework (P3).
      t.defines << 'MRB_STR_LENGTH_MAX=4194304'
    end
    conf.linker.flags += cpu_flags

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
