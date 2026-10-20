require 'shellwords'

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
def rpg_maker_gems(conf)
  # uni-algo is C++-only, so only the C++ compiler needs these.
  conf.cxx.defines += UNI_ALGO_TRIM_DEFINES
  # Opt-in (docs/bc2cpp-nomethod-verify.md, ADR 0275): a dead bc2cpp_nomethod site aborts
  # without dispatching. Off unless BC2CPP_NOMETHOD_VERIFY=1, so no shipped build changes.
  conf.cxx.defines << 'BC2CPP_NOMETHOD_VERIFY' if ENV['BC2CPP_NOMETHOD_VERIFY'] == '1'
  # Opt-in (ADR 0428): the strict-hint survey mode, each distinct violation logged once and dispatched.
  conf.cxx.defines << 'BC2CPP_HINT_VIOLATION_LOG' if ENV['BC2CPP_HINT_VIOLATION_LOG'] == '1'


  conf.gem core: 'mruby-array-ext'
  conf.gem core: 'mruby-hash-ext'
  # Enumerable#sort_by / min_by / max_by / group_by etc. mruby-array-ext does not
  # supply these — they live in mruby-enum-ext and are absent from the default
  # gem set, so calling e.g. Array#sort_by raises NoMethodError in the built
  # engine (the RPG2000 battle turn-order and message-pacing code both use it),
  # while the CRuby host checks pass. See scripts/rpg2k/boot_check.bash.
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
  # The closed build leaves it out: bc2cpp's canonical world is that build's
  # gem set (BC2CPP_CANONICAL_CORE_GEMS, tools/bc2cpp/compiled_gems.rb), and its
  # single-format game has no Dir caller (mruby-rpgxp, the only one, is absent).
  conf.gem core: 'mruby-dir' unless conf.name == 'closed'
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
  #
  # Both this and mruby-random below exist only for a game's *own* Ruby -- the
  # RGSS script host's Game_Battler/Game_Player/community scripts.
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
  #
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

  # Only the closed build carries the compiler: bc2cpp's source-loader check
  # (BC2CPP_SOURCE_LOADER_CALL, tools/bc2cpp/compiled_gems.rb) runs against it.
  conf.gem core: 'mruby-compiler' if conf.name == 'closed'

  conf.gem "#{MRUBY_ROOT}/../mruby-stringio"
  conf.gem "#{MRUBY_ROOT}/../mruby-marshal"

  # The closed build ships one RPG Maker format only, RPG2000/2003 (ADR 0061/0091/0097)
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
  # `closed` is the native bc2cpp build of the closed world (its stanza below).
  single_format_only = conf.name == 'closed'
  # docs/adr/0466: bc2cpp compiles closed-world programs only. RPGMAKER_BC2CPP=1
  # adds the compiled gems to the single-format builds, whose only Ruby is the
  # closed world; every other build (desktop, wasm, android, and the bootstrap
  # host of a cross build) loads or defines Ruby at runtime and stays the plain
  # mruby build.
  bc2cpp = ENV['RPGMAKER_BC2CPP'] && single_format_only

  conf.gem "#{MRUBY_ROOT}/../mruby-onig-regexp" do
    bundle_onigmo
  end unless single_format_only

  conf.gem "#{MRUBY_ROOT}/../../mruby-lcf"
  # docs/adr/0139: an opt-in, new parallel build path -- RPGMAKER_BC2CPP=1
  # swaps a hand-picked, provably-safe subset of LCF::File's own bytecode
  # methods (header/schema/terminate_root?/rpg2003?/maker/key?/to_lcf) for
  # C++ generated at build time by tools/bc2cpp/bc2cpp.rb from that exact
  # same mrblib source, with the ordinary interpreter (mruby-lcf, just
  # above) as the unconditional fallback for everything this doesn't
  # override. Never part of the default build for any target -- this whole
  # gem doesn't even exist in the gem list unless the env var is set.
  # docs/adr/0210: on single-format builds the closed world is all the Ruby
  # there is, so the compiled gems may replace a proven-dead by-name fallback
  # with a raise (tools/bc2cpp/compiled_gems.rb re-checks the real gem list).
  # ADR 0214: the same builds compile only tools/bc2cpp/hot_methods.txt to C++;
  # BC2CPP_HOT_ONLY=0 turns it off for a whole build; nothing turns it on for a build that did not opt in.
  closed_world = proc { enable_bc2cpp_hot_only }
  conf.gem "#{MRUBY_ROOT}/../../mruby-lcf-compiled", &closed_world if bc2cpp
  # mruby-rgss owns the shared RGSS namespace (Bitmap, Sprite, Viewport, Window,
  # ...). Every maker gem below loads after it and *reopens* that namespace, so a
  # class one of them defines under RGSS replaces mruby-rgss's for the whole
  # process -- which is what RPG2k's window did to the native RGSS::Window until
  # it became RPG2k::Window. Keep maker-specific classes under the maker's own
  # namespace.
  conf.gem "#{MRUBY_ROOT}/../../mruby-rgss"
  # docs/adr/0139: same opt-in mechanism as mruby-lcf-compiled/
  # mruby-rpg2k-compiled above, this time for all 17 of RGSS::Sprite's
  # real bytecode-defined methods.
  conf.gem "#{MRUBY_ROOT}/../../mruby-rgss-compiled", &closed_world if bc2cpp
  conf.gem "#{MRUBY_ROOT}/../../mruby-rpg2k"
  # docs/adr/0139's own follow-up: same opt-in mechanism, this time for 25
  # of Game::Picture's 26 real methods (everything but #initialize), plus
  # (docs/adr/0139) all 6 of Game::EnemyAction's own real methods.
  conf.gem "#{MRUBY_ROOT}/../../mruby-rpg2k-compiled", &closed_world if bc2cpp
  # docs/adr/0264: mruby's own Ruby (core mrblib, numeric-ext, range-ext) compiled
  # by the same pipeline, methods listed in tools/bc2cpp/core_methods.txt only.
  conf.gem "#{MRUBY_ROOT}/../../mruby-core-compiled", &closed_world if bc2cpp
  unless single_format_only
    conf.gem "#{MRUBY_ROOT}/../../mruby-rpgxp"
    conf.gem "#{MRUBY_ROOT}/../../mruby-rpgvx"
    conf.gem "#{MRUBY_ROOT}/../../mruby-wolf"
    conf.gem "#{MRUBY_ROOT}/../../mruby-mvjs"
  end

  rpg_maker_gem_dispatch(conf, single_format_only: single_format_only)
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
def rpg_maker_gem_dispatch(conf, single_format_only: false)
  # single_format_only (closed, see rpg_maker_gems) compiles mruby-rpg2k
  # alone -- the closure/dispatch machinery below still runs, generating a
  # trivial rpg_maker_init_rpg2k_gem with nothing to dispatch *between*, so
  # the two builds keep exactly one code path instead of a parallel
  # single-maker special case.
  maker_gem_names = if single_format_only
                       %w[mruby-rpg2k]
                     else
                       %w[mruby-rpg2k mruby-rpgxp mruby-rpgvx mruby-wolf mruby-mvjs]
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

    # A non-maker gem that depends directly on a maker gem (the opt-in
    # RPGMAKER_BC2CPP `mruby-rpg2k-compiled` -> `mruby-rpg2k`) needs what that
    # maker defines -- its init does mrb_module_get(M, "Game") -- so it cannot
    # sit in the always-init group, which runs before any maker. Initialise it
    # right after its maker, inside that maker's own init function. It also
    # stays out of the shared group, so a build that never picks that maker
    # (a single-format build) does not run it at all.
    after_maker = maker_gem_names.to_h { |name| [name, []] }
    active.each do |g|
      next if maker_gem_names.include?(g.name) || all_private_names.include?(g.name)

      owner = g.dependencies.map { |dep| dep[:gem] }.find { |dep| maker_gem_names.include?(dep) }
      after_maker[owner] << g if owner
    end
    all_after_maker = after_maker.values.flatten

    shared = active.reject do |g|
      maker_gem_names.include?(g.name) || all_private_names.include?(g.name) || all_after_maker.include?(g)
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
      (shared + maker_private.values.flatten + makers + all_after_maker).uniq.each do |g|
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
      # blocks the same way mvjs already had to, rather
      # than assuming every maker this dispatch has ever known about is
      # still active.
      rpg2k, rpgxp, rpgvx, wolf, mvjs = maker_gem_names.zip(makers).to_h.values_at(
        *%w[mruby-rpg2k mruby-rpgxp mruby-rpgvx mruby-wolf mruby-mvjs]
      )
      f.puts
      f.puts 'void rpg_maker_init_rpg2k_gem(mrb_state *mrb) {'
      maker_private['mruby-rpg2k'].each(&emit_call)
      emit_call.call(rpg2k)
      after_maker['mruby-rpg2k'].each(&emit_call)
      f.puts '}'
      if rpgxp
        f.puts
        f.puts 'void rpg_maker_init_rpgxp_gem(mrb_state *mrb) {'
        maker_private['mruby-rpgxp'].each(&emit_call)
        emit_call.call(rpgxp)
        after_maker['mruby-rpgxp'].each(&emit_call)
        f.puts '}'
      end
      if rpgvx
        f.puts
        f.puts 'void rpg_maker_init_rpgvx_gem(mrb_state *mrb) {'
        f.puts '  rpg_maker_init_rpgxp_gem(mrb); /* RGSS2/3 extends RGSS */'
        maker_private['mruby-rpgvx'].each(&emit_call)
        emit_call.call(rpgvx)
        after_maker['mruby-rpgvx'].each(&emit_call)
        f.puts '}'
      end
      if wolf
        f.puts
        f.puts 'void rpg_maker_init_wolf_gem(mrb_state *mrb) {'
        maker_private['mruby-wolf'].each(&emit_call)
        emit_call.call(wolf)
        after_maker['mruby-wolf'].each(&emit_call)
        f.puts '}'
      end
      if mvjs
        f.puts
        f.puts 'void rpg_maker_init_mvjs_gem(mrb_state *mrb) {'
        maker_private['mruby-mvjs'].each(&emit_call)
        emit_call.call(mvjs)
        after_maker['mruby-mvjs'].each(&emit_call)
        f.puts '}'
      end
    end
  end

  conf.libmruby_objs << conf.objfile(src.sub(/\.c$/, ''))
  file conf.objfile(src.sub(/\.c$/, '')) => src
end

# When cross-compiling (Emscripten, Android, or the closed bc2cpp build below) the
# host build only exists to produce the `mrbc` bytecode compiler, which must
# run natively during the cross build; the actual libmruby.a is produced by
# the cross build.
emscripten = ENV['MRUBY_TARGET'] == 'emscripten'
android = ENV['MRUBY_TARGET'] == 'android'
# The closed bc2cpp world, built natively (its stanza below).
closed = ENV['MRUBY_TARGET'] == 'closed'
cross = emscripten || android || closed

MRuby::Build.new do |conf|
  toolchain :gcc

  enable_debug

  if cross
    # Force native host compilers so `mrbc` runs on the build machine even when
    # CMake hands us a cross compiler via CC/CXX (emscripten's em++, or
    # Android's NDK clang++ -- root CMakeLists.txt's ANDROID branch configures
    # this whole project against the NDK toolchain, this "host" build included,
    # so without the override toolchain :gcc's own ENV['CC']/ENV['CXX'] fallback
    # would pick that cross compiler right back up). For the closed build the
    # host toolchain is invoked natively already, so the default cc/c++ are
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
    # MRUBY_FORCE_NO_CXX_EXCEPTION (a manual escape hatch, unset by the
    # closed build's scripts/bc2cpp/closed_build.bash) also stops load_gems.rb
    # from enabling C++ exceptions in THIS host build -- which then compiles the same .cxx gem
    # sources exception-free-or-not per its own flags below. Without the flag
    # they keep referencing the C++ runtime (__cxa_throw and friends) while
    # the host link stays plain gcc, and mrbc fails to link. Our sources use
    # no try/catch/throw (same verification as the cross half), so compiling
    # them exception-free here changes nothing but the link.
    conf.cxx.flags << '-fno-exceptions' if ENV['MRUBY_FORCE_NO_CXX_EXCEPTION']
    # mruby 4.0 always enables presym (MRB_NO_PRESYM / disable_presym were
    # removed) and serializes bytecode symbols by name, so the host mrbc and the
    # cross targets (emscripten, android) stay compatible even though their presym
    # tables differ.
  else
    enable_test

    [cc, cxx].each do |t|
      t.flags = t.flags.flatten.delete_if { |v| v == "-O0" }
    end

    rpg_maker_gems(conf)
  end
end

if closed
  # `closed`: the closed world compiled natively, for CI's `bc2cpp-build` job
  # (scripts/bc2cpp/closed_build.bash, docs/ci.md). bc2cpp compiles closed-world
  # builds only (docs/adr/0466), and a plain host compiler can build it with
  # the C++ exception mode bc2cpp's generated code needs: block `break`,
  # non-local `return` and `raise` are lowered to real C++ throw/catch, which
  # requires MRB_USE_CXX_EXCEPTION.
  #
  # The closed world is rpg_maker_gems with single_format_only (RPG2000/2003
  # only, no mruby-dir, mruby-compiler for the source-loader check, no mvjs)
  # and the stock mruby-io, so bc2cpp sees the same gem list, native sources
  # (tools/bc2cpp/compiled_gems.rb, BC2CPP_CLOSED_WORLD_HOST_SRCS) and foreign
  # Ruby. What it checks: the generation of the compiled gems and the
  # compilation of the generated code, with exceptions.
  MRuby::CrossBuild.new('closed') do |conf|
    toolchain :gcc

    # enable_debug's -O0 stays: this build is compiled to be checked, never run
    # for speed, and the generated files are large.
    enable_debug
    # The C++ exception mode the generated code assumes (load_gems.rb would also
    # turn it on for the gems' .cxx sources; this says so outright).
    enable_cxx_exception

    # Ruby-visible settings: bytecode without mrbc's `-g` tables, the same
    # string cap and heap/khash sizes, C++17.
    conf.mrbc.compile_options =
      conf.mrbc.compile_options.split(' ').reject { |o| o == '-g' }.join(' ')
    [conf.cc, conf.cxx].each do |t|
      t.defines << 'MRB_STR_LENGTH_MAX=0'
      t.defines << 'MRB_HEAP_PAGE_SIZE=256'
      t.defines << 'KHASH_INITIAL_SIZE=16'
    end
    conf.cxx.flags << '-std=gnu++17'

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
  # NOTE: this is the starting point for the
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
      # bare-metal targets (no __linux__) -- so no override is needed here.
    end

    rpg_maker_gems(conf)
  end
end

# Builds only the host's gem-free bootstrap mrbc (bin/mrbc, lib/libmruby_core.a,
# include/) -- all the bc2cpp CI check jobs need, without the gem build (ADR 0228).
desc 'build only the host bootstrap mrbc'
task host_mrbc: MRuby.targets['host'].mrbcfile
