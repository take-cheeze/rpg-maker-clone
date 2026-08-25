# The uni-algo modules this project never calls, switched off so their Unicode
# tables are never compiled in. This is the mirror of
# cmake/uni-algo-trim.cmake's RPG2K_UNI_ALGO_TRIM_DEFINES -- that file applies
# the same list to the CMake `uni-algo` target (which compiles the tables
# themselves, in its src/data.cpp), this one applies it to the mruby gems that
# include uni-algo's headers, so the two agree about which modules exist.
# **Keep the two lists in sync**; the reasoning, the measured sizes and which
# three uni-algo features this repo does use are all documented there rather
# than duplicated here. Note that the NFKC/NFKD define in that file is
# deliberately *not* mirrored here -- it is scoped to uni-algo's own data
# translation unit because uni-algo 1.2.0 cannot compile `impl_norm.h` with it
# set; see the comment beside RPG2K_UNI_ALGO_TRIM_DEFINES_DATA_ONLY.
#
# Called from rpg_maker_gems below rather than from each build block: the gems
# that include uni-algo's headers (mruby-rgss, mruby-lcf) are exactly the ones
# that method declares, so every build with those gems gets the flags and no
# build block can forget them.
UNI_ALGO_TRIM_DEFINES = %w[
  UNI_ALGO_DISABLE_CASE
  UNI_ALGO_DISABLE_PROP
  UNI_ALGO_DISABLE_SCRIPT
  UNI_ALGO_DISABLE_SEGMENT_GRAPHEME
  UNI_ALGO_DISABLE_SEGMENT_WORD
].freeze

# Gems shared by every build variant (the actual game libraries).
#
# include_mvjs: false drops mruby-mvjs (RPG Maker MV/MZ via embedded
# QuickJS). Only the psp cross-build passes this: mruby-mvjs's mrbgem.rake
# links against qjs (quickjs-ng, cross-compiled by the *root* CMakeLists.txt
# for the desktop/wasm targets only -- app/psp's standalone CMake project has
# no equivalent) and optionally EGL/GLESv2 for MZ's WebGL renderer, neither
# of which exists for MIPS/pspdev. RPG Maker MV/MZ support was never in scope
# for the PSP port (ADR 0010 only ever describes "starting the real RPG2k
# scene tree"), so this drops a gem that cannot link rather than attempting
# to port quickjs and a software GL stack to the PSP as a side effect of
# wiring RPG2k up.
def rpg_maker_gems(conf, include_mvjs: true)
  # uni-algo is C++-only, so only the C++ compiler needs these.
  conf.cxx.defines += UNI_ALGO_TRIM_DEFINES

  conf.gem core: 'mruby-array-ext'
  conf.gem core: 'mruby-hash-ext'
  # Enumerable#sort_by / min_by / max_by / group_by etc. mruby-array-ext does not
  # supply these — they live in mruby-enum-ext and are absent from the default
  # gem set, so calling e.g. Array#sort_by raises NoMethodError in the built
  # engine (the RPG2000 battle turn-order and message-pacing code both use it),
  # while the CRuby host checks pass. See scripts/rpg2k_boot_check.bash.
  conf.gem core: 'mruby-enum-ext'
  conf.gem core: 'mruby-io'
  # Dir: mruby-io stopped shipping it in mruby 4.0 -- the class moved to this
  # dedicated core gem (with its own hal-posix-dir/hal-win-dir backend, chosen
  # automatically the same way mruby-io picks its HAL). Nothing in the shared
  # list declared it, so the desktop binary only ever had Dir by accident:
  # mruby-rgss declares it as a *test* dependency below and the host build's
  # enable_test leaked that into the game link, while every cross target
  # (Android confirmed on-device) died in mrb_open() with "NameError:
  # uninitialized constant Dir" the moment mruby-rpgxp's rgss_library.rb --
  # which patches Dir.glob over it -- loaded. Declare it for real.
  conf.gem core: 'mruby-dir'
  conf.gem core: 'mruby-numeric-ext'
  # Fiber: the RGSS script host drives the game's bundled blocking main loop
  # (`$scene.main while $scene`) one frame at a time through a Fiber so the web
  # build's per-frame emscripten callback keeps control each frame. Not in the
  # default gem set (docs/adr/0023-rpgxp-script-host-frame-driver.md).
  conf.gem core: 'mruby-fiber'
  # Kernel#exit / SystemExit: the stock RMXP Interpreter calls `exit` to abort on
  # runaway common-event recursion; the script host provides it so that raises a
  # catchable SystemExit the driver ends the game on, rather than a NoMethodError.
  conf.gem core: 'mruby-exit'
  # Kernel#sprintf / #format and String#%: the RGSS script host runs the game's
  # bundled scripts, which format numbers with sprintf ("%02d" clocks, "%04d"
  # ids, "%+d", "%0*d", …). Not in the default gem set, so pull it in explicitly.
  conf.gem core: 'mruby-sprintf'
  # Kernel#Integer(): every RGSS game clamps its battler stats through it —
  # `n = [[Integer(n), 1].max, 999999].min` in Game_Battler_1, which runs the
  # moment a party member is built — so a game's own engine died on New Game
  # with "undefined method 'Integer'" without this. Same gem supplies Float() /
  # String() / Array(), which community scripts reach for.
  conf.gem core: 'mruby-kernel-ext'
  # Kernel#rand: a game's own scripts roll dice constantly — `Game_Player`
  # makes its encounter count with `rand(n) + rand(n) + 1` the moment New Game
  # places the party, damage variance uses it, and RPG::Weather scatters its
  # drops with it. This engine's own code deliberately uses seeded LCGs instead
  # (its runs are diffed frame by frame against the genuine runtimes), which is
  # why the gem was never needed until games ran their own code.
  conf.gem core: 'mruby-random'
  # The Math module. `Game_Character#jump` — stock RMXP, run by every game the
  # moment an event or a move route jumps — sizes its arc with
  # `Math.sqrt(x_plus * x_plus + y_plus * y_plus).round`, and community scripts
  # reach for sin/cos to move things in circles. Not in the default gem set:
  # mruby keeps Math in its own core gem (mrbgems/math.gembox).
  conf.gem core: 'mruby-math'
  # Time. Stock `Scene_Load` picks the newest save with `latest_time =
  # Time.at(0)` and `Window_SaveFile` stamps each slot with `file.mtime` — and
  # mruby-io's File#mtime answers a Time, so the save and load screens of every
  # game need this gem even though nothing in the engine's own code does. Only a
  # test dependency of mruby-io, so it does not come along for the ride.
  conf.gem core: 'mruby-time'
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
  # mruby-rgss owns the shared RGSS namespace (Bitmap, Sprite, Viewport, Window,
  # ...). Every maker gem below loads after it and *reopens* that namespace, so a
  # class one of them defines under RGSS replaces mruby-rgss's for the whole
  # process -- which is what RPG2k's window did to the native RGSS::Window until
  # it became RPG2k::Window. Keep maker-specific classes under the maker's own
  # namespace.
  conf.gem "#{MRUBY_ROOT}/../../mruby-rgss"
  conf.gem "#{MRUBY_ROOT}/../../mruby-rpg2k"
  conf.gem "#{MRUBY_ROOT}/../../mruby-rpgxp"
  conf.gem "#{MRUBY_ROOT}/../../mruby-rpgvx"
  conf.gem "#{MRUBY_ROOT}/../../mruby-mvjs" if include_mvjs
end

# When cross-compiling (Emscripten, Android, or the Wio Terminal below) the
# host build only exists to produce the `mrbc` bytecode compiler, which must
# run natively during the cross build; the actual libmruby.a is produced by
# the cross build.
emscripten = ENV['MRUBY_TARGET'] == 'emscripten'
wio = ENV['MRUBY_TARGET'] == 'wio'
psp = ENV['MRUBY_TARGET'] == 'psp'
android = ENV['MRUBY_TARGET'] == 'android'
cross = emscripten || wio || psp || android

MRuby::Build.new do |conf|
  toolchain :gcc

  enable_debug

  if cross
    # Force native host compilers so `mrbc` runs on the build machine even when
    # CMake hands us a cross compiler via CC/CXX (emscripten's em++, or
    # Android's NDK clang++ -- root CMakeLists.txt's ANDROID branch configures
    # this whole project against the NDK toolchain, this "host" build included,
    # so without the override toolchain :gcc's own ENV['CC']/ENV['CXX'] fallback
    # would pick that cross compiler right back up). For the Wio and PSP builds
    # the host toolchain is invoked natively already, so the default cc/c++ are
    # fine.
    if emscripten || android
      conf.cc.command = ENV['HOST_CC'] || 'cc'
      conf.cxx.command = ENV['HOST_CXX'] || 'c++'
      conf.linker.command = ENV['HOST_CXX'] || 'c++'
    end

    if android
      # toolchain :gcc above already read ENV['CFLAGS']/ENV['CXXFLAGS'] (both
      # set by root CMakeLists.txt's ANDROID branch to CMAKE_C_FLAGS, which
      # the NDK's android.toolchain.cmake seeds with cross-target flags:
      # -DANDROID, -D_FORTIFY_SOURCE=2, -fstack-protector-strong, ...) into
      # conf.cc.flags/conf.cxx.flags before this block ever ran. Those are
      # exactly right for the android cross target below (mruby's own
      # :android toolchain hardcodes its own real cross flags and never reads
      # CFLAGS/CXXFLAGS at all), but this "host" build compiles NATIVELY (the
      # command override just above) to produce mrbc -- and Android's
      # -DANDROID on a native compile broke it outright: it changes which
      # branch of mruby-compiler/core/parse.y's generated C++ lexer compiles,
      # and the result no longer compiles ("'mrb_reserved_word' was not
      # declared in this scope"). Reset to gcc.rake's own plain
      # native-compiler defaults (what it would have used with
      # CFLAGS/CXXFLAGS unset) plus enable_debug's -g3 -O0 from above, instead
      # of the cross target's flags.
      conf.cc.flags = [%w[-std=gnu99], %w[-g -O3 -Wall -Wundef], %w[-g3 -O0]]
      conf.cxx.flags = [%w[-g -O3 -Wall -Wundef], %w[-g3 -O0]]
      conf.linker.flags = []
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
      # Bare-metal newlib falls through mruby's string.c to a 1 MiB default cap
      # (see below); game data (maps/images loaded as strings, and whole packed
      # archives read in one shot by RGSSAD.open) can exceed that many times
      # over, so disable the cap outright (0 = unlimited), matching what
      # mruby already does for free on Linux/macOS/BSD. Actual RAM fit is a
      # separate concern handled by the streaming rework (P3).
      t.defines << 'MRB_STR_LENGTH_MAX=0'
      # The micro-controller tuning knobs from mruby's own mrbconf.h (the
      # MRB_CONSTRAINED_BASELINE_PROFILE set, minus MRB_NO_METHOD_CACHE which
      # costs dispatch speed on a CPU-bound handheld): a smaller GC heap page
      # (256 vs 1024 objects) cuts the slack an under-filled last page wastes,
      # and a smaller initial khash bucket count (16 vs 32) shrinks the symbol
      # and instance-variable tables that start nearly empty. Both are pure
      # footprint wins with no behaviour change -- the same object graph just
      # allocates in smaller, tighter units. See
      # docs/adr/0047-psp-memory-budget.md.
      t.defines << 'MRB_HEAP_PAGE_SIZE=256'
      t.defines << 'KHASH_INITIAL_SIZE=16'
    end
    conf.linker.flags += cpu_flags

    rpg_maker_gems(conf)
  end
end

if psp
  # Cross build for the Sony PlayStation Portable (Allegrex, MIPS32 R4000 with a
  # VFPU). Produces a libmruby.a that the pspdev EBOOT (app/psp, its
  # CMakeLists.txt) links; the host build above supplies mrbc.
  #
  # NOTE: like the Wio build this is the starting point for the port in
  # docs/adr/0010-psp-port.md, not a finished, fitting build. The bring-up EBOOT
  # links neither libmruby nor the input bridge yet; this cross target exists so
  # the interpreter can be layered on in the next slice. It is only built when
  # MRUBY_TARGET=psp, so it never affects the desktop or wasm builds.
  MRuby::CrossBuild.new('psp') do |conf|
    toolchain :gcc

    conf.cc.command = 'psp-gcc'
    conf.cxx.command = 'psp-g++'
    conf.linker.command = 'psp-gcc'
    conf.archiver.command = 'psp-ar'

    # onigmo's (old) config.sub needs a triplet it recognizes to enter
    # cross-compile mode; mipsel-unknown-linux keeps the 32-bit little-endian
    # word size and only forces cross mode (the real compiler is still psp-gcc).
    conf.host_target = 'mipsel-unknown-linux'

    enable_debug

    # enable_debug also appends ` -g` to mrbc's own compile options (default
    # "-B%{funcname} -o-", see mruby's Command::Mrbc#initialize), which embeds
    # line-number/local-variable debug tables in every gem's compiled mrblib
    # bytecode -- the game's own Ruby (mruby-rpg2k, mruby-rgss, mruby-lcf, ...),
    # not mruby's C core. Unlike the C-level -g3 kept below (native DWARF, never
    # mapped into RAM -- ELF debug sections sit outside every PT_LOAD segment),
    # mrb_load_irep parses these Ruby-level tables into live heap structures the
    # moment the interpreter boots: measured at roughly 240-350 KB of live RAM
    # for the rpg2k+lcf+rgss mrblib stack alone (docs/adr/0047-psp-memory-budget.md),
    # against a 4 MB LVGL pool that may have to cover mruby's whole heap too. It
    # buys nothing on a device with no interactive Ruby debugger attached to it,
    # so strip it from mrbc the same way -O0 is stripped from cc/cxx below.
    # (mruby's own mruby-bin-strip gem -- not part of this project's gem set --
    # removes the same debug tables after the fact and gives byte-identical
    # output to this, so this is equivalent to stripping post-compile.)
    conf.mrbc.compile_options =
      conf.mrbc.compile_options.split(' ').reject { |o| o == '-g' }.join(' ')

    # Allegrex ABI. -G0 disables gp-relative small-data addressing (pspsdk links
    # expect this); PSP_BUILD gates the psp.cxx / psp_input_bridge.cxx HAL in the
    # mruby-rgss gem on. Must be identical on compile and link lines so the mruby
    # objects match the EBOOT's ABI.
    cpu_flags = %w[-G0]

    # pspsdk's own headers (pspctrl.h, pspdisplay.h, pspkernel.h, ... --
    # needed once PSP_BUILD turns on the real psp.cxx / psp_input_bridge.cxx
    # HAL below) live outside psp-gcc's baked-in sysroot; psp-cmake's
    # toolchain file adds this automatically for CMake's own compiles (main.cxx,
    # LVGL, uni-algo), but this Rakefile drives psp-gcc/psp-g++ directly and
    # gets none of that, so ask pspsdk's own discovery tool for the path
    # instead of hardcoding one.
    pspsdk_include = "#{`psp-config --pspsdk-path`.strip}/include"

    [conf.cc, conf.cxx].each do |t|
      t.flags = t.flags.flatten.delete_if { |v| v == '-O0' }
      t.flags += cpu_flags
      t.include_paths << pspsdk_include
      t.defines << 'PSP_BUILD'
      # newlib on the PSP defines none of __linux__/__APPLE__/__*BSD__, so
      # mruby's string.c falls through to the 1 MiB MRB_STR_LENGTH_MAX cap and
      # rejects larger strings. Game data (maps, images loaded as strings, and
      # whole packed archives read in one shot by RGSSAD.open) can exceed that
      # many times over, so disable the cap outright (0 = unlimited), matching
      # the wasm/Wio builds and what mruby already does for free on
      # Linux/macOS/BSD.
      t.defines << 'MRB_STR_LENGTH_MAX=0'
      # Same micro-controller knobs as the Wio build above (see its comment):
      # a 256-object GC heap page and 16-entry initial khash buckets cut the
      # interpreter's live footprint on the PSP's ~24 MB without any
      # behaviour change.
      t.defines << 'MRB_HEAP_PAGE_SIZE=256'
      t.defines << 'KHASH_INITIAL_SIZE=16'
      # stb_image's FILE*-based stbi_load(path, ...) is only ever called by
      # mruby-mvjs's mvcanvas.cxx (MV/MZ's Image loader); this cross-build
      # excludes mvjs (include_mvjs: false below) and mruby-rgss's own loader
      # always reads bytes itself and decodes via stbi_load_from_memory (see
      # bmp_decode_into, mruby-rgss/src/lib.cxx), so the stdio path is dead
      # code here. Dropping it removes newlib's stdio-backed stb decode path
      # (and the buffered-FILE state it pulls in) from the one PT_LOAD-mapped
      # EBOOT that would otherwise carry it unused.
      t.defines << 'STBI_NO_STDIO'
    end
    conf.linker.flags += cpu_flags

    rpg_maker_gems(conf, include_mvjs: false)
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
      # On native platforms mruby defaults MRB_STR_LENGTH_MAX to 0 (unlimited),
      # but Emscripten defines none of __linux__/__APPLE__/__*BSD__, so
      # string.c falls through to a 1 MiB cap and rejects larger strings with
      # "string too long". Game data (maps, images loaded as strings) routinely
      # exceeds 1 MiB, and RGSSAD.open reads a whole packed archive into a
      # single String, so any fixed cap just moves the crash to a bigger file
      # (e.g. a real archive of 5.5 MiB blew past a prior 4 MiB cap here).
      # Disable the cap outright, matching the native builds.
      t.defines << 'MRB_STR_LENGTH_MAX=0'
    end

    rpg_maker_gems(conf)
  end
end

if android
  # Cross build for Android (NDK, via mruby's own built-in :android toolchain
  # -- tasks/toolchains/android.rake, upstream mruby, not something this
  # project carries). Produces a libmruby.a that app/android's Gradle build
  # links, through root CMakeLists.txt's own ANDROID branch (see
  # docs/adr/0058-android-port.md).
  #
  # NOTE: like the Wio and PSP builds, this is the starting point for the
  # port -- a single ABI (arm64-v8a, matching app/android/app/build.gradle's
  # abiFilters) rather than the full armeabi-v7a/arm64-v8a/x86/x86_64 set a
  # Play Store release would ship. Adding a second ABI is a matter of
  # widening both that abiFilters list and the ANDROID_ARCH root
  # CMakeLists.txt is configured with per build -- mruby's own toolchain
  # already parameterizes on it (MRuby::Toolchain::Android::ARCHITECTURES).
  # It is only built when MRUBY_TARGET=android, so it never affects the
  # desktop or wasm builds.
  MRuby::CrossBuild.new('android') do |conf|
    # ANDROID_NDK_HOME/ANDROID_ARCH/ANDROID_PLATFORM come from root
    # CMakeLists.txt's ANDROID branch (the real NDK path and the ABI/API level
    # CMake itself was configured with via android.toolchain.cmake), so this
    # target always matches whatever the surrounding C++ build is doing rather
    # than a second, independently-maintained guess at the same values.
    toolchain :android,
              ndk_home: ENV['ANDROID_NDK_HOME'],
              arch: ENV['ANDROID_ARCH'],
              sdk_version: Integer(ENV.fetch('ANDROID_PLATFORM', '28'))

    # The real triple mruby's :android toolchain targets (aarch64 for
    # arm64-v8a); needed for mruby-onig-regexp's autotools-built onigmo to
    # enter cross-compile mode. Only covers the one ABI this port currently
    # builds -- widening ARCHITECTURES support above needs a matching case
    # here.
    conf.host_target = 'aarch64-linux-android'

    enable_debug

    [conf.cc, conf.cxx].each do |t|
      t.flags = t.flags.flatten.delete_if { |v| v == '-O0' }
      # Bionic (Android's libc) is Linux-based and mruby's string.c already
      # detects __linux__ to default MRB_STR_LENGTH_MAX to unlimited, unlike
      # the Wio/PSP bare-metal targets above -- so no override is needed here.
    end

    rpg_maker_gems(conf)
  end
end
