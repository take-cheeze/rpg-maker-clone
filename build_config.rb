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

# docs/adr/0119: wio-only, per-gem build step. Rewrites a copy of each of
# spec's own .rb files (never the checked-in source itself) to drop
# $stderr.puts diagnostic statements before mrbc ever sees them --
# strip_wio_debug_output.rb's own file comment covers the mechanism and why
# it is a real Ripper-based rewrite rather than a regex/sed pass. A no-op
# for every other target (build.name != 'wio'): desktop/wasm/psp keep every
# line, including the ones mruby-rgss/mrblib/error_report.rb's Tee
# specifically exists to capture into a crash report and a terminal log
# console -- see that file's own comment. Call this *last* in a gem's own
# spec block, after every other spec.rbfiles filter (debug-tools/battle
# trims, schema.rb's own blob swap, ...): it replaces each surviving
# entry's path outright, so anything that still needs to subtract or
# substitute an entry by its original path has to run before this does.
def wio_strip_debug_rbfiles(spec)
  return unless spec.build.name == 'wio'

  strip_script = File.expand_path('strip_wio_debug_output.rb', __dir__)
  out_dir = "#{spec.build_dir}/wio_debug_stripped"
  spec.rbfiles = spec.rbfiles.map do |src|
    rel = src.sub(/\A#{Regexp.escape(spec.dir)}\//, '')
    out = "#{out_dir}/#{rel}"
    file out => [src, strip_script] do |t|
      FileUtils.mkdir_p File.dirname(out), verbose: true
      ruby strip_script, src, out
    end
    out
  end
end

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
  #
  # wio is the one exception: its bare arm-none-eabi newlib has no dirent
  # implementation at all (a hard #error in <dirent.h>, unlike PSP's own
  # pspsdk newlib), which is exactly what hal-posix-dir needs -- and nothing
  # reachable there needs Dir at all in the first place: mruby-rpgxp is the
  # only real caller (rgss_library.rb's Dir.glob patch) and it is already
  # excluded from wio's own single_format_only gem set below, so unlike the
  # desktop/android history above, there is no live NameError risk to guard
  # against by keeping it.
  conf.gem core: 'mruby-dir' unless conf.name == 'wio'
  conf.gem core: 'mruby-numeric-ext'
  # Range#cover? lives here, not in core Range. Five call sites in mruby-rpg2k
  # (Game::Shop#equip?, the special-item checks in game.rb / item_menu.rb)
  # used it while nothing declared the gem, so a shop whose highlighted good
  # was equipment -- and the Item screen with a special item -- raised
  # NoMethodError in the built engine while the CRuby host checks passed.
  conf.gem core: 'mruby-range-ext'
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

  # psp/wio ship one RPG Maker format only, RPG2000/2003 (ADR 0061/0091/0097)
  # -- unlike desktop/wasm/android, which run whichever format a game
  # directory on disk turns out to be (rpg_maker_gem_dispatch below picks the
  # matching one at runtime). mruby-rpgxp (RPG Maker XP), mruby-rpgvx (VX/VX
  # Ace, itself add_dependency'd on rpgxp) and mruby-wolf (WOLF RPG Editor)
  # are dead weight there: 30,812 + 11,994 + 82,367 = 125,173 bytes of the
  # ~639 KB this project's mrblib compiles to in total, measured with real
  # `mrbc -g` the same way ADR 0097's debug-tools trim was. mruby-onig-regexp
  # (onigmo, "easily hundreds of KB" per ADR 0007) goes with them: profiling
  # mruby-rpg2k/mruby-lcf/mruby-rgss's own mrblib for Regexp/=~/.match/.scan
  # found none (mruby-rpg2k/mrblib/main.rb even says so outright, "this mruby
  # build bundles neither a regexp engine nor String#strip") -- every real
  # user is one of the three gems this drops (mruby-wolf's Picture window-
  # shape tags, mruby-rpgxp's Dir.glob fallback, mruby-mvjs's JSON/HTML
  # scanning), so nothing left needs it once they're gone. See docs/adr/
  # 0098-rpg2k-single-format-trim.md.
  single_format_only = %w[psp wio].include?(conf.name)

  conf.gem "#{MRUBY_ROOT}/../mruby-onig-regexp" do
    bundle_onigmo
  end unless single_format_only

  conf.gem "#{MRUBY_ROOT}/../../mruby-lcf"
  # mruby-rgss owns the shared RGSS namespace (Bitmap, Sprite, Viewport, Window,
  # ...). Every maker gem below loads after it and *reopens* that namespace, so a
  # class one of them defines under RGSS replaces mruby-rgss's for the whole
  # process -- which is what RPG2k's window did to the native RGSS::Window until
  # it became RPG2k::Window. Keep maker-specific classes under the maker's own
  # namespace.
  conf.gem "#{MRUBY_ROOT}/../../mruby-rgss"
  conf.gem "#{MRUBY_ROOT}/../../mruby-rpg2k"
  unless single_format_only
    conf.gem "#{MRUBY_ROOT}/../../mruby-rpgxp"
    conf.gem "#{MRUBY_ROOT}/../../mruby-rpgvx"
    conf.gem "#{MRUBY_ROOT}/../../mruby-wolf"
    conf.gem "#{MRUBY_ROOT}/../../mruby-mvjs" if include_mvjs
  end

  rpg_maker_gem_dispatch(conf, include_mvjs: include_mvjs, single_format_only: single_format_only)
end

# mrb_open() eagerly runs *every* configured gem's init -- defining every
# class and method mruby-rpg2k, mruby-rpgxp, mruby-rpgvx and mruby-mvjs carry,
# whichever single one of them a run actually uses (docs/adr/0047's Finding 1
# measured ~1.2-1.4 MB of live heap for rpg2k+lcf+rgss's mrblib alone, before
# rpgxp/rpgvx/mvjs are even counted). src/main.cxx knows which maker a game
# directory is before it opens mruby (RPG_RT.ldb / Game.ini / js/rpg_core.js /
# .rvdata* are plain filesystem checks), so it can skip initialising the ones
# it will never use -- but mruby's own generated mrb_init_mrbgems() (called
# from mrb_open()) is one flat, unconditional loop with no per-gem opt-out.
#
# This generates a small sibling to that file, built from the *same* resolved
# `conf.gems` mrbgems.rake itself computed (gems.setup_build / gems.check
# already ran by the time this file task's recipe actually runs, since Rake
# loads every task file -- including this one -- before invoking any of
# them), so it can never drift out of sync with build_config.rb's own gem
# list the way a hand-copied call order would: it walks each maker's own
# `add_dependency` chain (mruby-lcf for mruby-rpg2k; mruby-eval and the
# Binding/Method/Proc-ext trio mruby-rpgxp's own eval dependency pulls in;
# ...) to find the gems *only* that one maker needs, and puts everything
# else -- including a gem two makers both happen to need, e.g. mruby-rgss
# itself, which every maker gem depends on -- in the always-init group. The
# split reuses the *same* generated GENERATED_TMP_mrb_<funcname>_gem_init
# entry points mrb_init_mrbgems already calls, so it costs nothing beyond
# which function calls which of them. See src/main.cxx's "Deferred per-maker
# gem init" section for the call side.
def rpg_maker_gem_dispatch(conf, include_mvjs:, single_format_only: false)
  # single_format_only (psp/wio, see rpg_maker_gems) compiles mruby-rpg2k
  # alone -- the closure/dispatch machinery below still runs, generating a
  # trivial rpg_maker_init_rpg2k_gem with nothing to dispatch *between*, so
  # the two builds keep exactly one code path instead of a parallel
  # single-maker special case.
  maker_gem_names = if single_format_only
                       %w[mruby-rpg2k]
                     else
                       %w[mruby-rpg2k mruby-rpgxp mruby-rpgvx mruby-wolf] +
                         (include_mvjs ? %w[mruby-mvjs] : [])
                     end
  src = "#{conf.build_dir}/mrbgems/rpg_maker_gem_dispatch.c"

  # Gems declared directly, at the top of rpg_maker_gems, rather than pulled
  # in only as some other gem's add_dependency: those calls are this
  # project's own explicit "every build variant needs this" list (see that
  # method's comment), so they stay in the always-init group even where one
  # happens to *also* sit on a single maker's dependency chain -- mruby-lcf
  # is only add_dependency'd by mruby-rpg2k, but it is its own top-level
  # conf.gem call too, so it is not this dispatch's call to demote.
  explicit_shared_names = %w[
    mruby-array-ext mruby-hash-ext mruby-enum-ext mruby-io mruby-dir
    mruby-numeric-ext mruby-range-ext mruby-fiber mruby-exit mruby-sprintf mruby-kernel-ext
    mruby-random mruby-math mruby-time mruby-bigint mruby-stringio
    mruby-marshal mruby-onig-regexp mruby-lcf mruby-rgss
  ]

  file src => "#{conf.build_dir}/mrbgems/gem_init.c" do |t|
    active = conf.gems.select(&:generate_functions)
    by_name = active.each_with_object({}) { |g, h| h[g.name] = g }
    makers = maker_gem_names.map do |name|
      by_name.fetch(name) do
        fail "rpg_maker_gem_dispatch: gem '#{name}' is not active/generating"
      end
    end

    # Every (transitive) prerequisite a maker gem's own add_dependency chain
    # reaches, not counting a *sibling* maker reached along the way (rpgvx
    # depends on rpgxp, but rpgxp's own private prerequisites -- eval and
    # friends -- belong to rpgxp's bucket, not rpgvx's; rpgvx gets them by
    # calling rpg_maker_init_rpgxp_gem itself, below).
    closure_of = lambda do |root|
      seen = {}
      stack = [root]
      until stack.empty?
        g = stack.pop
        next if seen[g.name]
        seen[g.name] = true
        next if g.name != root.name && maker_gem_names.include?(g.name)
        g.dependencies.each do |dep|
          dep_gem = by_name[dep[:gem]]
          stack << dep_gem if dep_gem
        end
      end
      seen.keys - maker_gem_names
    end

    # A prerequisite more than one maker's closure claims (mruby-rgss itself,
    # chief among them -- every maker gem depends on it) can only ever be
    # initialised once, so it has to live in the always-init group rather
    # than any single maker's bucket.
    maker_closures = makers.map { |m| closure_of.call(m) }
    claim_counts = Hash.new(0)
    maker_closures.each { |cl| cl.each { |n| claim_counts[n] += 1 } }
    private_names = maker_closures.map do |cl|
      cl.select { |n| claim_counts[n] == 1 && !explicit_shared_names.include?(n) }
    end
    all_private_names = private_names.flatten

    shared = active.reject do |g|
      maker_gem_names.include?(g.name) || all_private_names.include?(g.name)
    end
    maker_private = maker_gem_names.each_with_index.to_h do |name, i|
      [name, active.select { |g| private_names[i].include?(g.name) }]
    end

    mkdir_p File.dirname(t.name)
    open(t.name, 'w') do |f|
      f.puts '/* Generated by build_config.rb (rpg_maker_gem_dispatch).'
      f.puts ' * See its comment for what this is and why it exists. */'
      f.puts
      f.puts '#include <mruby.h>'
      f.puts '#include <mruby/error.h>'
      f.puts
      (shared + maker_private.values.flatten + makers).uniq.each do |g|
        f.puts "void GENERATED_TMP_mrb_#{g.funcname}_gem_init(mrb_state*);"
      end
      f.puts

      emit_call = lambda do |g|
        f.puts "  GENERATED_TMP_mrb_#{g.funcname}_gem_init(mrb);"
        f.puts '  if (mrb->exc) mrb_exc_raise(mrb, mrb_obj_value(mrb->exc));'
      end

      f.puts 'void rpg_maker_init_shared_gems(mrb_state *mrb) {'
      shared.each(&emit_call)
      f.puts '}'

      # single_format_only's maker_gem_names is just ['mruby-rpg2k'], so
      # rpgxp/rpgvx/wolf/mvjs all come out nil here -- guard each of their
      # blocks the same way mvjs already had to (include_mvjs: false), rather
      # than assuming every maker this dispatch has ever known about is
      # still active.
      rpg2k, rpgxp, rpgvx, wolf, mvjs = maker_gem_names.zip(makers).to_h.values_at(
        *%w[mruby-rpg2k mruby-rpgxp mruby-rpgvx mruby-wolf mruby-mvjs]
      )
      f.puts
      f.puts 'void rpg_maker_init_rpg2k_gem(mrb_state *mrb) {'
      maker_private['mruby-rpg2k'].each(&emit_call)
      emit_call.call(rpg2k)
      f.puts '}'
      if rpgxp
        f.puts
        f.puts 'void rpg_maker_init_rpgxp_gem(mrb_state *mrb) {'
        maker_private['mruby-rpgxp'].each(&emit_call)
        emit_call.call(rpgxp)
        f.puts '}'
      end
      if rpgvx
        f.puts
        f.puts 'void rpg_maker_init_rpgvx_gem(mrb_state *mrb) {'
        f.puts '  rpg_maker_init_rpgxp_gem(mrb); /* RGSS2/3 extends RGSS */'
        maker_private['mruby-rpgvx'].each(&emit_call)
        emit_call.call(rpgvx)
        f.puts '}'
      end
      if wolf
        f.puts
        f.puts 'void rpg_maker_init_wolf_gem(mrb_state *mrb) {'
        maker_private['mruby-wolf'].each(&emit_call)
        emit_call.call(wolf)
        f.puts '}'
      end
      if mvjs
        f.puts
        f.puts 'void rpg_maker_init_mvjs_gem(mrb_state *mrb) {'
        maker_private['mruby-mvjs'].each(&emit_call)
        emit_call.call(mvjs)
        f.puts '}'
      end
    end
  end

  conf.libmruby_objs << conf.objfile(src.sub(/\.c$/, ''))
  file conf.objfile(src.sub(/\.c$/, '')) => src
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

if wio
  # docs/adr/0112: wio's own RAM/flash margin (ADR 107/111) is tight enough
  # that the GOTHIC (JIS0208 kanji) face's SD offload (ADR 110) -- previously
  # a no-op-unless-set escape hatch, same as every other opt-in knob in this
  # series -- is now this target's *default*, not something a caller has to
  # remember to ask for. `||=` so an explicit override (e.g. a measurement
  # build that wants the old compiled-in GOTHIC array back) still wins.
  # SHINONOME_GOTHIC_SD_FILE is read by gen_shinonome_data.rb from inside
  # mruby-rgss's own build_dir (mrbgem.rake's Dir.chdir), so a bare filename
  # lands there rather than needing an absolute path computed this early.
  # RGSS_SHINONOME_GOTHIC_SD_PATH is the on-device path baked into the
  # firmware; no real SD deployment step writes gothic.bin there yet (ADR
  # 110's own "what was not done" section), so this only fixes what the
  # *build* produces -- getting the generated file onto a real card remains
  # future work.
  ENV['SHINONOME_GOTHIC_SD_FILE'] ||= 'gothic.bin'
  ENV['RGSS_SHINONOME_GOTHIC_SD_PATH'] ||= '/gothic.bin'
end

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

    # A real `pio run -e wio_rgss_boot` link surfaced a whole class of bogus
    # undefined references (__aeabi_read_tp, from stack-protector code no
    # bare-metal newlib here implements) that turned out to have nothing to
    # do with mruby-rgss at all: a bare `arm-none-eabi-gcc` resolves via PATH
    # to this machine's distro package (13.2.1, built with
    # -fstack-protector-strong baked into ITS OWN defaults) rather than
    # PlatformIO's own bundled toolchain (7.2.1, which the final link always
    # uses) -- two different compiler majors, silently disagreeing on ABI
    # and codegen defaults, is not something any amount of flag-matching can
    # paper over. Prefer PlatformIO's own copy so the object files this rake
    # build produces are built by the exact same compiler that links them;
    # fall back to plain PATH resolution (the prior behaviour) where that
    # package isn't installed, e.g. a standalone measurement-only build (see
    # RGSS_WIO_STUB_HEADERS above) never needs a real link to agree with.
    pio_gcc_bin = "#{ENV['HOME']}/.platformio/packages/toolchain-gccarmnoneeabi/bin"
    gcc_prefix = Dir.exist?(pio_gcc_bin) ? "#{pio_gcc_bin}/" : ''
    conf.cc.command = "#{gcc_prefix}arm-none-eabi-gcc"
    conf.cxx.command = "#{gcc_prefix}arm-none-eabi-g++"
    conf.linker.command = "#{gcc_prefix}arm-none-eabi-gcc"
    conf.archiver.command = "#{gcc_prefix}arm-none-eabi-ar"

    # onigmo's (old) config.sub needs a triplet it recognizes to enter
    # cross-compile mode; arm-none-eabi is such a bare-metal triple.
    conf.host_target = 'arm-none-eabi'

    enable_debug

    # enable_debug also appends ` -g` to mrbc's own compile options (default
    # "-B%{funcname} -o-", see mruby's Command::Mrbc#initialize), which embeds
    # line-number/local-variable debug tables in every gem's compiled mrblib
    # bytecode -- the game's own Ruby (mruby-rpg2k, mruby-rgss, mruby-lcf,
    # mruby's own core mrblib, ...), not mruby's C core. Unlike the C-level
    # -g3 kept below (native DWARF, never mapped into RAM -- ELF debug
    # sections sit outside every PT_LOAD segment), mrb_load_irep parses these
    # Ruby-level tables into live heap structures the moment the interpreter
    # boots -- docs/adr/0047-psp-memory-budget.md already measured this at
    # roughly 240-350 KB of live RAM for the very same rpg2k+lcf+rgss mrblib
    # stack on PSP, and made this same fix there. Wio never got the sibling
    # fix: real host-side `mrbc` runs on this project's own rpg2k mrblib (16
    # files, minus the debug-menu/battle files already trimmed above) show
    # `-g` alone costs 85,188 bytes on that slice alone, before rgss/lcf/core
    # are even counted -- and unlike PSP's ~24 MB+ budget, wio's 192 KB RAM
    # has nowhere to absorb a boot-time cost of that shape at all (docs/adr/
    # 0111 already found one hidden-RAM bug invisible to every static relink
    # measurement this series relies on; this is the same class of risk).
    conf.mrbc.compile_options =
      conf.mrbc.compile_options.split(' ').reject { |o| o == '-g' }.join(' ')

    # --remove-lv (MRB_DUMP_NO_LVAR) drops a *second* debug-only table, the
    # separate local-variable name array -- it exists purely for
    # introspection/backtraces (`Kernel#local_variables`, a debugger) this
    # firmware never calls, confirmed by grepping every rpg2k/rgss/lcf .rb
    # file for eval/instance_eval/class_eval/binding, all absent. Passing it
    # to mrbc alone does *not* work here, though: this build's own
    # Command::Mrbc#run always adds `-S` (mrbgem.rake's `cdump: true`,
    # mruby's default), which routes through mruby's own src/cdump.c rather
    # than the *binary* .mrb path (src/dump.c) -- and cdump.c's own two
    # `if (irep->lv)` checks never look at MRB_DUMP_NO_LVAR at all, unlike
    # dump.c's `lv_defined = (flags & MRB_DUMP_NO_LVAR) ? FALSE : ...`. A
    # real gap in mruby's own C-struct dumper (confirmed: a real relink with
    # 3rd/mruby/src/cdump.c locally patched to also check the flag recovers
    # a further 43,416 bytes on top of the `-g` strip above), not something
    # fixable from this file alone -- 3rd/mruby is the real upstream
    # mruby/mruby, not a fork this project can push a patch to. Get the same
    # effect from this side of the fence instead: wrap conf.mrbc's own `run`
    # to strip the `<name>_lv_<N>` array mruby's compiler always populates
    # (mrbgems/mruby-compiler/core/codegen.c does this unconditionally for
    # every scope with named locals -- there is no compile-time flag to stop
    # it at the source) out of the C source cdump.c already wrote, the same
    # way ADR 111 patched a build-time generator rather than the C++ it fed
    # instead of leaving the runtime construction broken.
    conf.mrbc.define_singleton_method(:run) do |out, *args, **kwargs|
      method(:run).super_method.call(out, *args, **kwargs)
      path = out.path
      src = File.read(path)
      src.gsub!(/^mrb_DEFINE_SYMS_VAR\(\w+_lv_\d+, .*\);\n/, '')
      src.gsub!(/^(  )(\w+_lv_\d+),\n/, "\\1NULL,\t\t\t\t\t/* lv */\n")
      File.write(path, src)
    end

    # Cortex-M4F with hardware single-precision FPU. Must be identical on the
    # compile and link lines so the mruby objects match the firmware's ABI.
    cpu_flags = %w[-mcpu=cortex-m4 -mthumb -mfloat-abi=hard -mfpu=fpv4-sp-d16]

    # Dev/measurement escape hatch, a no-op unless set: wio.cxx's real HAL
    # (mruby-rgss/src/wio.cxx) needs Arduino.h/TFT_eSPI.h, which normally only
    # exist inside a PlatformIO build (app/wio's own env:wio already has
    # them). Pointing this at a directory with minimal declaration-only stubs
    # of both lets `MRUBY_TARGET=wio rake` produce a real, complete libmruby.a
    # standalone -- e.g. for a real arm-none-eabi-size measurement -- without
    # a PlatformIO project. NOT suitable for an actual PlatformIO link: TFT_eSPI
    # is a real stateful C++ class (fields, a Print base), and wio.cxx embeds a
    # `TFT_eSPI g_tft` global by value, so the object's size and layout must
    # match the real class exactly -- a declarations-only stub compiles fine
    # but silently gives g_tft the wrong (too small, unrelated) layout, which
    # the real library's own methods then read/write past. See
    # RGSS_WIO_ARDUINO_INCLUDES below for the real-headers alternative this
    # implies. Nothing in this repo sets either by default.
    [conf.cc, conf.cxx].each { |t| t.include_paths << ENV['RGSS_WIO_STUB_HEADERS'] } if ENV['RGSS_WIO_STUB_HEADERS']

    # Real-link escape hatch, a no-op unless set: points wio.cxx's compile at
    # the actual PlatformIO framework headers (Arduino.h, TFT_eSPI.h and their
    # own transitive includes -- CMSIS, the SAMD51 device headers, the board's
    # variant.h) instead of the measurement-only stub above, so the resulting
    # wio.o is truly ABI-compatible with a real `pio run -e wio_rgss_boot`
    # link: same extern "C" linkage and parameter types for pinMode/
    # digitalRead/delay/millis (the stub had the wrong types and was missing
    # extern "C" entirely, so the linker looked for mangled C++ symbols no
    # framework object ever defines), and the same true TFT_eSPI layout.
    # RGSS_WIO_ARDUINO_INCLUDES is a colon-separated list of -I directories --
    # see docs/adr/0103-wio-mruby-rgss-first-real-build.md's follow-up ADR for
    # the exact set (extracted from a real `pio run -v` compile of a
    # PlatformIO-framework file, since the PlatformIO package cache paths are
    # host- and package-version-specific and cannot be hardcoded here). The
    # defines below are true Wio Terminal board/toolchain constants, not host
    # paths, so they are hardcoded rather than threaded through the
    # environment -- they only apply once real Arduino headers are actually
    # in play.
    if ENV['RGSS_WIO_ARDUINO_INCLUDES']
      ENV['RGSS_WIO_ARDUINO_INCLUDES'].split(':').each { |p| conf.cxx.include_paths << p }
      conf.cxx.defines +=
        %w[PLATFORMIO=60200 __SAMD51P19A__ SEEED_WIO_TERMINAL SEEED_GROVE_UI_WIRELESS __SAMD51__
           __FPU_PRESENT ARM_MATH_CM4 VARIANT_QSPI_BAUD_DEFAULT=50000000 TXRXLED_ENABLE ROLE=0
           ARDUINO=10805 F_CPU=120000000L USBCON USB_VID=0x2886 USB_PID=0x802D ARDUINO_ARCH_SAMD
           USB_CONFIG_POWER=100]
    end

    # Not gated behind RGSS_WIO_ARDUINO_INCLUDES above: this is a real,
    # always-applicable fix, found the same way (a real `pio run -e
    # wio_rgss_boot` link). GCC's C++11 thread-safe static-local-variable
    # guards (mruby-rgss's stb_image-derived decoders and mruby-lcf's cp932
    # conversion both have function-local statics with non-trivial init)
    # compile, on ARM EABI, to an inline fast path that reads the current
    # thread id via __aeabi_read_tp -- a helper no arm-none-eabi newlib
    # multilib in this toolchain actually defines (single-threaded bare-metal
    # firmware has no thread pointer to read), so the link fails outright.
    # PlatformIO's own Arduino framework compiles already build every C++
    # file with this same flag for the same reason; libmruby.a just never
    # picked it up before there was a real, non-stub link to catch it.
    conf.cxx.flags << '-fno-threadsafe-statics'

    # mruby-lcf and mruby-rgss both need C++17 (uni-algo's own conv.h hard-
    # errors below it, and mruby-lcf/src/lcf.cxx includes <optional>). Every
    # other cross build here (host, wasm) gets this for free because the
    # system/emsdk compiler's OWN default standard happens to already be new
    # enough -- but PlatformIO's bundled arm-none-eabi-g++ is GCC 7.2.1,
    # whose default (gnu++14) is not, and using PlatformIO's own toolchain
    # (see the gcc_prefix comment above) is exactly what surfaced this.
    conf.cxx.flags << '-std=gnu++17'

    # docs/adr/0120/0122: unlike -fno-exceptions (reverted -- mruby's own
    # core needs real C++ exceptions whenever any gem has a C++ source),
    # -fno-rtti has no auto-re-enabling gem-loader hook to fight and no
    # other blocker once lib.cxx's own one real `typeid` use (a
    # per-type diagnostic label on each DataType<T>::data_type, ADR 122)
    # is replaced with a plain static name each wrapped type supplies
    # itself. Matches PlatformIO's own Arduino framework build
    # (platformio.ini's own comment on this).
    conf.cxx.flags << '-fno-rtti'

    [conf.cc, conf.cxx].each do |t|
      t.flags = t.flags.flatten.delete_if { |v| v == '-O0' }
      t.flags += cpu_flags
      # mruby's own gcc.rake defaults to -O3 (dropping only the debug
      # build's -O0 above leaves that -O3 in place, same as PSP's own cross
      # build); PSP has UMD-backed storage to spare, but the Wio Terminal's
      # 512 KB internal flash does not -- a real `pio run -e wio_rgss_boot`
      # link overflows FLASH by over 1.5 MB even before this. -Os (GCC's
      # last -O flag wins) trades some speed for meaningfully smaller code,
      # the same tradeoff PlatformIO's own Arduino framework build already
      # makes for this board. Still nowhere near enough on its own to fit --
      # see docs/adr/0103-wio-mruby-rgss-first-real-build.md's follow-up ADR.
      t.flags << '-Os'
      # Neither this rake-driven compile nor mruby's own gcc.rake defaults set
      # these, so every mrbgem's whole .text/.data/.bss lands in one section
      # per object file -- env:wio_rgss_boot's real link already passes
      # `-Wl,--gc-sections` (PlatformIO's own Arduino/LVGL build already
      # needs it for the same reason), but that can only drop a section
      # entirely, so one live symbol anywhere in a .o keeps every other
      # unused function and global data table in that same file too. Splitting
      # each function/global into its own section lets --gc-sections actually
      # prune at that granularity instead. Confirmed real, not just reasoned
      # about in the abstract: a real env:wio_rgss_boot link's own flash
      # overflow dropped by 196,012 bytes from this alone, and
      # mruby-rgss/src/iterm.cxx and sixel.cxx (dead PNG/sixel-encoding code
      # on wio -- see terminal.cxx's own file comment) are now provably
      # absent from the linked image's own map file, closing
      # docs/adr/0103's own flagged gap without ever needing an explicit
      # PSP_BUILD/WIO_TERMINAL guard on either file. See
      # docs/adr/0105-wio-flash-shrink-sections-and-font-subsetting.md.
      t.flags << '-ffunction-sections' << '-fdata-sections'
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
      # Mirrors PSP_BUILD below: gates the wio.cxx HAL in the mruby-rgss gem
      # on and the desktop-only sixel/iTerm2 terminal.cxx backend off (that
      # file's own guard is `#if !defined(PSP_BUILD) && !defined(WIO_TERMINAL)`).
      # PlatformIO's app/wio build already defines this for the app half
      # (platformio.ini's `-DWIO_TERMINAL`); this rake-driven libmruby.a needs
      # its own copy since it never sees that build's flags.
      t.defines << 'WIO_TERMINAL'
      # docs/adr/0115 already found and stripped mrbc's own `-g` (Ruby-level
      # line-number/local-variable debug tables baked into compiled
      # bytecode); enable_debug's `-g3` on this same cc/cxx loop is its
      # harmless C-level sibling (native DWARF, never mapped into RAM -- ELF
      # debug sections sit outside every PT_LOAD segment, same reasoning
      # docs/adr/0047-psp-memory-budget.md already gave). MRB_DEBUG is a
      # third, different thing enable_debug also defines here: a C
      # preprocessor flag (mruby.h) that turns mrb_assert(...) -- used
      # ~100 times across mruby's own core (vm.c/gc.c/class.c/dump.c/...,
      # not counting mrbgems) -- from a no-op into a real libc assert(),
      # each one a real branch plus a string literal holding the assertion
      # source text and file/line for every call site. Real, unavoidable
      # flash cost for checks that would only ever fire on an actual mruby
      # VM/GC bug (this project's own code, not a game's), which a device
      # with no attached debugger and no serial console wired to it in this
      # firmware could not usefully report anyway -- a failed assert here
      # just calls abort() into nothing. Not part of ADR 115's own fix (a
      # different mechanism, mrbc vs cc/cxx), so removed separately.
      t.defines.delete('MRB_DEBUG')
    end
    conf.linker.flags += cpu_flags

    # Own HAL for mruby-io (see its own file comment): this board's bare
    # newlib is close enough to POSIX for plain file I/O (open/read/write/
    # lseek/fstat/unlink all compile and, once app/wio/src/sd_syscalls.cxx's
    # WIO_WITH_SD syscalls are linked in by the firmware, work), but has none
    # of hal-posix-io's wider POSIX surface (lstat, symlinks, fork/exec,
    # select) -- and none of that surface is reachable from a real
    # RPG2000/2003 game running through this exporter's own file access
    # anyway. Added before rpg_maker_gems (which pulls in mruby-io itself) so
    # mruby-io's own "no HAL specified" auto-selection never fires here.
    conf.gem "#{MRUBY_ROOT}/../../hal-wio-io"

    rpg_maker_gems(conf)

    # Tried and reverted: -fno-exceptions, matching PlatformIO's own Arduino
    # framework build (platformio.ini's own comment on this). This project's
    # own .cxx files (mruby-rgss/src, mruby-lcf/src, app/wio/src) have no
    # try/catch/throw at all, but that turned out not to be the real
    # question -- mruby's own gem loader (lib/mruby/build/load_gems.rb)
    # auto-enables MRB_USE_CXX_EXCEPTION the moment any gem has a .cxx
    # source (mruby-rgss/mruby-lcf/mruby-marshal all do here), which
    # compiles mruby's own core error.c as C++ (build/wio/.../error-cxx.cxx)
    # and implements Ruby's own begin/rescue/ensure -- MRB_TRY/MRB_CATCH,
    # src/throw.h -- as real C++ throw/catch rather than setjmp/longjmp,
    # specifically because longjmp does not run C++ destructors and would
    # leak/corrupt any C++ object on the stack being unwound through. A
    # real, load-bearing use of exceptions this build cannot do without:
    # -fno-exceptions fails to even compile mruby's own core
    # ("'e' was not declared in this scope" inside MRB_CATCH's own
    # expansion). Not attempted further.
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
