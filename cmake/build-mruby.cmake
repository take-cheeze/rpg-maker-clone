# Shared logic for building libmruby.a via mruby's own rake-based build system
# (build_config.rb), used by both the desktop/wasm build (root CMakeLists.txt)
# and the PSP EBOOT build (app/psp/CMakeLists.txt). mruby's gem system -- which
# C sources, generated headers, gembox membership -- is entirely decided by that
# Rakefile, not by anything CMake can glob on its own, so this drives rake as an
# external build system via a custom command rather than declaring a native
# CMake target.
#
# rpg2k_add_mruby() takes TARGET_NAME (the mruby build's own name -- build.name
# in build_config.rb, e.g. "host", "emscripten", "psp"), REPO_ROOT (repo root:
# build_config.rb, 3rd/mruby and 3rd/mgem-list all hang off this),
# PROJECT_BUILD_DIR (the calling project's CMAKE_CURRENT_BINARY_DIR), GEMS
# (local mrbgem dirs to watch for rebuild triggers, e.g. mruby-rgss) and an
# optional MRB_OPTS (extra rake VAR=value args beyond the
# MRUBY_CONFIG/MRUBY_BUILD_DIR/PROJECT_BUILD_DIR this function always sets
# itself).
#
# Defines an IMPORTED STATIC `mruby` target (INTERFACE-including its generated
# presym header dir) and a `mruby_build` custom target that `mruby` depends on.
function(rpg2k_add_mruby)
  set(one_value_args TARGET_NAME REPO_ROOT PROJECT_BUILD_DIR)
  set(multi_value_args GEMS MRB_OPTS)
  cmake_parse_arguments(ARG "" "${one_value_args}" "${multi_value_args}"
                        ${ARGN})

  set(mruby_prefix "${ARG_REPO_ROOT}/3rd/mruby")
  set(mruby_build_dir "${ARG_PROJECT_BUILD_DIR}/mruby")
  set(libmruby_a "${mruby_build_dir}/${ARG_TARGET_NAME}/lib/libmruby.a")
  # mruby 4.0 always enables presym, so <mruby.h> unconditionally pulls in
  # <mruby/presym.h> and its generated mruby/presym/id.h. That header lives in
  # the build tree (produced by the rake build below), not in the source include
  # dir, so expose it too. Create it now so CMake's imported-target check --
  # which requires INTERFACE include dirs to exist at configure time -- passes
  # before the build populates it.
  set(mruby_gen_include "${mruby_build_dir}/${ARG_TARGET_NAME}/include")
  file(MAKE_DIRECTORY "${mruby_gen_include}")

  add_library(mruby STATIC IMPORTED)
  set_target_properties(mruby PROPERTIES IMPORTED_LOCATION "${libmruby_a}")
  target_include_directories(mruby INTERFACE "${mruby_prefix}/include"
                                             "${mruby_gen_include}")

  # Collect the source of each local mrbgem so libmruby.a rebuilds when any of
  # it changes. GLOB_RECURSE also picks up files in nested subdirectories, and
  # CONFIGURE_DEPENDS makes CMake re-run the glob at build time: adding or
  # removing a source file triggers a reconfigure (and thus a libmruby rebuild)
  # on the next build, with no manual `cmake` re-run. Header changes under src/
  # are caught too so an edit to a private header still forces the archive to be
  # rebuilt.
  foreach(g ${ARG_GEMS})
    file(
      GLOB_RECURSE
      src
      CONFIGURE_DEPENDS
      ${ARG_REPO_ROOT}/${g}/src/*.c
      ${ARG_REPO_ROOT}/${g}/src/*.cxx
      ${ARG_REPO_ROOT}/${g}/src/*.cpp
      ${ARG_REPO_ROOT}/${g}/src/*.h
      ${ARG_REPO_ROOT}/${g}/src/*.hpp
      ${ARG_REPO_ROOT}/${g}/src/*.hxx)
    file(GLOB_RECURSE rb CONFIGURE_DEPENDS ${ARG_REPO_ROOT}/${g}/mrblib/*.rb)
    list(APPEND mrb_files ${src} ${rb} ${ARG_REPO_ROOT}/${g}/mrbgem.rake)
  endforeach()

  # Also rebuild libmruby.a when mruby's own core changes. These sources live in
  # the 3rd/mruby submodule; CONFIGURE_DEPENDS keeps the list current as the
  # submodule is checked out or updated to a new revision.
  file(
    GLOB_RECURSE
    mruby_core
    CONFIGURE_DEPENDS
    ${mruby_prefix}/src/*.c
    ${mruby_prefix}/src/*.h
    ${mruby_prefix}/mrblib/*.rb
    ${mruby_prefix}/include/*.h)
  list(APPEND mrb_files ${mruby_core})

  # Real, confirmed gap found and fixed this round (docs/adr/0139's own bc2cpp
  # bug-hunt sweep): tools/bc2cpp/bc2cpp.rb and tools/bc2cpp/compiled_gems.rb
  # live outside every mrbgem directory entirely (this script's own doc comment
  # above already explains why: this one tool feeds
  # mruby-lcf-compiled's/mruby-rpg2k-compiled's/ mruby-rgss-compiled's own
  # mrbgem.rake `file` rules, none of which are in a fixed, single gem's own
  # src/ or mrblib/ tree), so neither file was ever a member of `mrb_files`
  # above -- this custom command's own DEPENDS list (below) never named either
  # one, and Ninja/Make only ever re-runs a custom command when something in its
  # OWN declared DEPENDS changed, not when a file it has no idea the command
  # reads changes. Confirmed LIVE, not hypothetical: editing either file and
  # re-running a plain `cmake --build` (no reconfigure, no `rake` invoked by
  # hand) produced `ninja: no work to do` -- the previous, now-stale
  # `*_compiled_gen.cpp`/`*_decls.h` a PRIOR build already generated kept being
  # linked in unchanged, silently discarding the edit rather than regenerating
  # it, for every one of the three compiled gems at once
  # (`rpg2k_compiled_gen.cpp` was still dated from before this round's own
  # `compiled_gems.rb`/`register.cxx` edits after a real incremental rebuild
  # reported success). This is exactly the class of "silent miscompile" this
  # project's own established verification discipline exists to catch -- a
  # `cmake --build && ctest` that reports green while actually still testing the
  # PREVIOUS round's own generated code is far worse than a build that fails
  # loudly, and would have let this round's own `Game.singleton` addition (and
  # any future one) look verified without ever actually being exercised.
  # `tools/bc2cpp/mrb_files.rb` doesn't exist -- there's no third file this tool
  # reads at build time beyond these two.
  file(GLOB bc2cpp_files CONFIGURE_DEPENDS ${ARG_REPO_ROOT}/tools/bc2cpp/*.rb)
  list(APPEND mrb_files ${bc2cpp_files})
  # The hot-method list a BC2CPP_HOT_ONLY build compiles (docs/adr/0214).
  list(APPEND mrb_files ${ARG_REPO_ROOT}/tools/bc2cpp/hot_methods.txt)

  set(mrb_opts
      MRUBY_CONFIG=${ARG_REPO_ROOT}/build_config.rb
      MRUBY_BUILD_DIR=${mruby_build_dir}
      PROJECT_BUILD_DIR=${ARG_PROJECT_BUILD_DIR} ${ARG_MRB_OPTS})

  # Vendored mruby carries a real upstream compiler bug (patches/mruby-colon3-
  # assign-setmcnst.patch's own preamble has the full trail): `::Const = value`
  # written inside a nested module/class body silently defines the constant on
  # the *lexically enclosing* module instead of at the top level -- no
  # exception, just the wrong owner. Real, not vendor-specific: `ruby -e 'module
  # Foo; ::Bar = 42; end; p Object.const_defined?(:Bar)'` prints true, mruby's
  # does not. This submodule tracks upstream mruby/mruby directly (no fork this
  # project controls to carry the fix on), so it is patched in place here
  # instead, the same way patches/psp-fixup-imports-jal-relocation-aware. patch
  # is applied to a fetched pspsdk checkout -- via a real script
  # (scripts/apply_mruby_patch.bash), not a `patch` call embedded straight in
  # this COMMAND: it needs a dry-run-first idempotency check across repeat
  # configures/builds without re-cloning the submodule, and that redirect- heavy
  # shell logic does not survive CMake's own command-line escaping reliably
  # inline. The script itself fails loudly (not silently) if the patch stops
  # applying, e.g. after a future submodule bump moves the patched code -- see
  # its own preamble.
  set(mruby_colon3_patch
      "${ARG_REPO_ROOT}/patches/mruby-colon3-assign-setmcnst.patch")

  # Vendored mruby never implemented `$!` (Kernel#$!, "the exception the current
  # rescue clause is handling") -- it always reads nil, even inside an active
  # rescue (patches/mruby-dollar-bang-scoped.patch's own preamble has the full
  # trail, including two rejected earlier approaches). Found via a real VX Ace
  # game's bundled crash-reporter add-on (docs/rpgvx-rgss-api-gap.md, item 7),
  # which calls `$!.message` inside its own rescue clause and got a
  # NoMethodError instead, masking the game's original exception behind an
  # unrelated crash. Same patch-in-place treatment as the colon3 patch above,
  # for the same reason (no fork of upstream mruby/mruby this project controls).
  set(mruby_dollar_bang_patch
      "${ARG_REPO_ROOT}/patches/mruby-dollar-bang-scoped.patch")

  # Vendored mruby never implemented the `defined?` keyword at all -- neither
  # the lexer nor the grammar recognized it, so `defined?(Foo)` parsed as an
  # ordinary method call named `defined?` and raised NoMethodError instead of
  # answering the question at compile time (patches/mruby-defined-keyword.
  # patch's own preamble has the full trail: which of the lexer, grammar, and
  # codegen pieces were missing, the register-allocation pitfall its codegen
  # helpers have to account for, and the two documented simplifications versus
  # real Ruby). Real, not vendor-specific: upstream mruby 3.3.0 has never
  # implemented this keyword either. Found via a real VX Ace game's
  # speech-bubble add-on (docs/rpgvx-rgss-api-gap.md), which guards a
  # SceneManager lookup with `defined?(SceneManager)` and crashed with
  # NoMethodError on the very first frame it ran. Same patch-in-place treatment
  # as the colon3 and `$!` patches above, for the same reason (no fork of
  # upstream mruby/mruby this project controls).
  set(mruby_defined_keyword_patch
      "${ARG_REPO_ROOT}/patches/mruby-defined-keyword.patch")

  # Vendored mruby never implemented bare `module_function` (the "every method
  # def'd from here on in this module body becomes a module function" scope
  # form, called with no arguments) -- a literal no-op stub in src/class.c's own
  # mrb_mod_module_function: `if (argc == 0) { /* set MODFUNC SCOPE if
  # implemented */ return mod; }`. `ruby -e 'module Foo; module_function; def
  # bar(x); x*2; end; end; p Foo.bar(3)'` returns 6 in CRuby; the same script
  # raised `NoMethodError: undefined method 'bar' for Module` under unpatched
  # vendored mruby (patches/mruby- module-function-scope.patch's own preamble
  # has the full trail, including why the fix reuses -- rather than replaces --
  # the existing bare private/protected/public scope-tracking machinery, and the
  # two previously-unused/ZERO-documented flag bits it spends to do it).
  # Verified against mruby's own full bundled mrbtest suite: identical 1874 OK /
  # 0 KO before and after (the one environment-only "Crash" is a
  # sandboxed-container UDPSocket permission gap, reproduces unpatched too,
  # unrelated to this patch). Found scoping tools/optcarrot_probe (see its own
  # README.md) against optcarrot's real upstream source, which uses exactly this
  # idiom in lib/optcarrot/driver.rb and lib/optcarrot/palette.rb. Same
  # patch-in-place treatment as the other mruby patches above, for the same
  # reason (no fork of upstream mruby/mruby this project controls).
  set(mruby_module_function_scope_patch
      "${ARG_REPO_ROOT}/patches/mruby-module-function-scope.patch")

  # `mrbc -v`'s own parse-tree dump (mrb_parser_dump, parse.y) prints garbage --
  # and can emit an invalid UTF-8 byte sequence doing it -- for a `$&`/`` $`
  # ``/`$'`/`$+` or `$1`/`$2`/... node, because its NODE_BACK_REF/ NODE_NTH_REF
  # cases read `node_to_int(tree)` (a raw heap pointer cast to int) instead of
  # that node's own real stored `.type`/`.nth` field
  # (patches/mruby-parser-dump-back-nth-ref.patch's own preamble has the full
  # trail and a real repro). Debug-dump-only: mrb_parser_dump is never called
  # from the actual compiler/codegen path, so this changes no compiled bytecode,
  # only what `-v`'s own text output shows for these two node kinds -- but
  # tools/bc2cpp/bc2cpp.rb reads exactly that text, and crashes outright on the
  # invalid byte sequence. Verified against mruby's own full bundled mrbtest
  # suite, same as the module-function-scope patch above: identical 1874 OK / 0
  # KO before and after. Found scoping tools/optcarrot_probe (see its own
  # README.md) -- optcarrot's own lib/optcarrot/opt.rb:74 has the real `$1`/`$'`
  # use that hit this. Same patch-in-place treatment as the other mruby patches
  # above, for the same reason (no fork of upstream mruby/mruby this project
  # controls).
  set(mruby_parser_dump_back_nth_ref_patch
      "${ARG_REPO_ROOT}/patches/mruby-parser-dump-back-nth-ref.patch")

  # Vendored mruby's own out-of-memory recovery has two real gaps
  # (patches/mruby-nomemoryerror-reentrant-alloc.patch's own preamble has the
  # full trail, including a host-native repro harness built against this
  # project's own exact PSP arena allocator): the pre-allocated
  # NoMemoryError/SystemStackError/arena-overflow singletons were never actually
  # frozen, so raising one of them can still trigger a second, avoidable
  # allocation (a backtrace capture) at exactly the moment there is no room
  # left; and mrb_open() cannot tell mrb_core_init_abort()'s deliberate
  # mrb->exc=NULL apart from genuine success, so an allocation failure early
  # enough in bootstrap lets it proceed into gem init on a half-initialized
  # state instead of failing cleanly. Found chasing P1c
  # (docs/adr/0047-psp-memory-budget.md), though the repro did not reproduce
  # P1c's own exact crash signature -- these are real, independently verified
  # fixes, not a confirmed fix for P1c itself. Same patch-in-place treatment as
  # the other mruby patches above, for the same reason (no fork of upstream
  # mruby/mruby this project controls).
  set(mruby_nomem_patch
      "${ARG_REPO_ROOT}/patches/mruby-nomemoryerror-reentrant-alloc.patch")

  # Vendored mruby has no way to see what a live heap is made of by type -- the
  # stock answer, the mruby-objectspace mrbgem's ObjectSpace.count_objects,
  # forces a full mrb_full_gc() before every walk (patches/mruby-gc-type-
  # live-counts.patch's own preamble has the full trail), which is the exact
  # stop-the-world cost this project's profiler exists to watch for, so it
  # cannot be the thing that watches for it. This patch instead adds a
  # per-mrb_vtype live/allocation counter pair to mrb_gc, kept current by a
  # single increment already-executing mrb_obj_alloc() and a single decrement in
  # the sweep phase's obj_free() -- no extra heap walk, no extra GC pass -- plus
  # mrb_gc_type_counts() to read them out, which mruby-rgss/src/ profiler.cxx
  # uses to report per-type object counts through RGSS::Profiler.stats. Unlike
  # the other patches here this is a project- owned addition rather than an
  # upstream bug fix, so it is not expected to ever land upstream and stays
  # permanently. Same patch-in-place treatment as the rest of this file, for the
  # same reason (no fork of upstream mruby/mruby this project controls).
  set(mruby_gc_type_counts_patch
      "${ARG_REPO_ROOT}/patches/mruby-gc-type-live-counts.patch")

  # Vendored mruby-io's file.c unconditionally uses MAXPATHLEN (a `char
  # buf[MAXPATHLEN]` in path_getwd, backing Dir.getwd/File.expand_path) after
  # `#include <sys/param.h>` on every non-Windows target -- true on glibc and
  # most BSD/Darwin libcs, but this board's bare-metal arm-none-eabi newlib's
  # own sys/param.h defines PATHSIZE, not MAXPATHLEN, so the file fails to
  # compile outright (a real `MRUBY_TARGET=wio rake` run against PlatformIO's
  # own toolchain-gccarmnoneeabi never got this far before -- see
  # docs/adr/0103-wio-mruby-rgss-first-real-build.md's follow-up ADR). Adds the
  # same `#ifndef MAXPATHLEN #define MAXPATHLEN 1024` fallback the file's own
  # _WIN32 branch already carries a few lines up, just gated for any libc
  # missing the macro rather than only Windows's. Same patch-in- place treatment
  # as the other mruby patches above, for the same reason (no fork of upstream
  # mruby/mruby this project controls).
  set(mruby_io_maxpathlen_patch
      "${ARG_REPO_ROOT}/patches/mruby-io-maxpathlen-fallback.patch")

  # 3rd/mruby-stringio's StringIO has no native `getbyte` -- mruby's own
  # `IO`/`File` does (mruby-io's io_getbyte, a bare Integer with no allocation),
  # but every LCF chunk (mruby-lcf/mrblib/lcf.rb) is decoded through a StringIO,
  # not a File, and used to emulate the method in Ruby via `getc.getbyte(0)` --
  # riding on #getc, which allocates and returns a fresh one-character String on
  # every single byte scanned while walking a table's chunk boundaries.
  # Measurably slow: a New Game/Continue transition decoding Nepheshel's item
  # and common-event tables this way cost ~370ms of a ~400ms scene.update
  # outlier (docs/profiling.md's "New Game/Continue transition" section has the
  # full trail and Before/after numbers). This submodule is project-controlled
  # (github.com/take-cheeze/mruby-stringio) rather than a true upstream this
  # project has no fork of, but this session's repo access is scoped to
  # rpg-maker-clone only, with no push access to push a commit to
  # mruby-stringio's own remote -- so it is patched in place here the same way
  # the mruby-proper patches above are, for the same practical reason (no commit
  # landed on that other repo's history for a pinned submodule bump to point
  # at). A future contributor with access to that repo could instead land this
  # upstream and drop this patch on the next submodule bump.
  set(mruby_stringio_getbyte_patch
      "${ARG_REPO_ROOT}/patches/mruby-stringio-native-getbyte.patch")
  set(mruby_stringio_prefix "${ARG_REPO_ROOT}/3rd/mruby-stringio")

  # mruby-marshal's own mrbgem.rake unconditionally add_dependency'd
  # mruby-onig-regexp, silently defeating ADR 0098's psp/wio onigmo trim (that
  # ADR's own top-level conf.gem exclusion never stopped this unconditional
  # dependency from pulling onigmo right back in) -- not noticed until a real
  # end-to-end MRUBY_TARGET=wio build first ran to completion. Made conditional,
  # paired with a marshal.cpp fix so Marshal.dump/load do not hard-require the
  # Regexp class to exist at all once onigmo (which alone defines it) is really
  # gone. Same project-owned-submodule, no-push-access reasoning as the
  # mruby-stringio patch above: mruby-marshal is take-cheeze's own repo, but
  # this session's access is scoped to rpg-maker-clone, so it is patched in
  # place here instead.
  set(mruby_marshal_onigmo_patch
      "${ARG_REPO_ROOT}/patches/mruby-marshal-psp-wio-onigmo-optional.patch")
  set(mruby_marshal_prefix "${ARG_REPO_ROOT}/3rd/mruby-marshal")

  # docs/adr/0134 measurement-only escape hatch, a no-op unless
  # MRUBY_FORCE_NO_CXX_EXCEPTION is set in the environment: mruby's own gem
  # loader (lib/mruby/build/load_gems.rb) unconditionally calls
  # enable_cxx_exception the moment any gem has a .cxx/.cpp/.cc source
  # (mruby-rgss/mruby-lcf/mruby-marshal all do here), which compiles mruby's own
  # core error.c/vm.c/gc.c as real C++ and implements Ruby's own begin/
  # rescue/ensure as real C++ throw/catch (src/throw.h) rather than setjmp/
  # longjmp -- specifically because longjmp does not run C++ destructors and
  # would leak any C++ object (std::string/std::vector, real ones exist on
  # mruby-rgss's own call stacks) left on the stack being unwound through. This
  # patch only adds the environment-variable check itself; it changes nothing
  # for every normal build, on any target, where that variable is unset. See the
  # ADR for the real, measured flash number this unlocks and, just as
  # importantly, why it is a real correctness tradeoff this project has not
  # decided to accept as the default.
  set(mruby_force_no_cxx_exception_patch
      "${ARG_REPO_ROOT}/patches/mruby-force-no-cxx-exception-escape-hatch.patch"
  )

  # mruby-onig-regexp builds its bundled onigmo inside Dir.chdir blocks, which
  # change every rake thread's cwd; the patch keeps `rake -m` safe (ADR 0228).
  set(mruby_onig_regexp_no_chdir_patch
      "${ARG_REPO_ROOT}/patches/mruby-onig-regexp-no-chdir.patch")
  set(mruby_onig_regexp_prefix "${ARG_REPO_ROOT}/3rd/mruby-onig-regexp")

  # Flash/RAM trims for the static irep and presym data every build embeds
  # (docs/adr/0223, 0224, 0225). The first two change no behaviour; the third
  # only adds the MRB_NO_IREP_DEBUG option, which only the wio build defines.
  set(mruby_presym_compact_patch
      "${ARG_REPO_ROOT}/patches/mruby-presym-compact-table.patch")
  set(mruby_cdump_const_reps_patch
      "${ARG_REPO_ROOT}/patches/mruby-cdump-const-reps.patch")
  set(mruby_no_irep_debug_patch
      "${ARG_REPO_ROOT}/patches/mruby-no-irep-debug.patch")

  # One `apply_mruby_patch.bash DIR PATCH &&` link per patch, run in this order
  # ahead of rake by both mruby_build and mruby_host_mrbc below.
  set(mruby_patch_chain "")
  set(mruby_patch_files "")
  macro(rpg2k_mruby_patch dir patch)
    list(APPEND mruby_patch_chain
         "${ARG_REPO_ROOT}/scripts/apply_mruby_patch.bash" "${dir}" "${patch}"
         &&)
    list(APPEND mruby_patch_files "${patch}")
  endmacro()
  rpg2k_mruby_patch("${mruby_prefix}" "${mruby_colon3_patch}")
  rpg2k_mruby_patch("${mruby_prefix}" "${mruby_dollar_bang_patch}")
  rpg2k_mruby_patch("${mruby_prefix}" "${mruby_defined_keyword_patch}")
  rpg2k_mruby_patch("${mruby_prefix}" "${mruby_module_function_scope_patch}")
  rpg2k_mruby_patch("${mruby_prefix}" "${mruby_parser_dump_back_nth_ref_patch}")
  rpg2k_mruby_patch("${mruby_prefix}" "${mruby_nomem_patch}")
  rpg2k_mruby_patch("${mruby_prefix}" "${mruby_gc_type_counts_patch}")
  rpg2k_mruby_patch("${mruby_prefix}" "${mruby_io_maxpathlen_patch}")
  rpg2k_mruby_patch("${mruby_stringio_prefix}"
                    "${mruby_stringio_getbyte_patch}")
  rpg2k_mruby_patch("${mruby_marshal_prefix}" "${mruby_marshal_onigmo_patch}")
  rpg2k_mruby_patch("${mruby_onig_regexp_prefix}"
                    "${mruby_onig_regexp_no_chdir_patch}")
  rpg2k_mruby_patch("${mruby_prefix}" "${mruby_force_no_cxx_exception_patch}")
  rpg2k_mruby_patch("${mruby_prefix}" "${mruby_presym_compact_patch}")
  rpg2k_mruby_patch("${mruby_prefix}" "${mruby_cdump_const_reps_patch}")
  rpg2k_mruby_patch("${mruby_prefix}" "${mruby_no_irep_debug_patch}")

  # Point mruby's rake at the vendored mgem-list (the mgem index) via symlinks
  # in its repos/ dir so it resolves gems locally instead of cloning from
  # GitHub. Both repos/host and repos/<TARGET_NAME> are linked: a cross build
  # (emscripten, psp, ...) also runs a native "host" build alongside the cross
  # target to produce mrbc, and that half looks for the index under its own
  # repos/host too. Use `ln -sfn`, not `ln -sf`: once these links exist, a plain
  # `ln -sf` would dereference the existing symlink-to-directory and drop a new
  # link *inside* 3rd/mgem-list (a self-referential 3rd/mgem-list/mgem-list),
  # dirtying the submodule. `-n` (no-dereference; portable across GNU and
  # BSD/macOS) replaces the symlink in place instead.
  set(mruby_rake_command
      ${mruby_patch_chain} mkdir -p ${mruby_build_dir}/repos/host
      ${mruby_build_dir}/repos/${ARG_TARGET_NAME} && ln -sfn
      ${ARG_REPO_ROOT}/3rd/mgem-list ${mruby_build_dir}/repos/host/mgem-list &&
      ln -sfn ${ARG_REPO_ROOT}/3rd/mgem-list
      ${mruby_build_dir}/repos/${ARG_TARGET_NAME}/mgem-list && ${mrb_opts} rake
      -v)

  add_custom_command(
    OUTPUT "${libmruby_a}"
    COMMAND ${mruby_rake_command}
    WORKING_DIRECTORY "${mruby_prefix}"
    DEPENDS "${ARG_REPO_ROOT}/build_config.rb" ${mruby_patch_files}
            ${mrb_files})
  add_custom_target(mruby_build DEPENDS "${libmruby_a}")
  add_dependencies(mruby mruby_build)

  # Only the gem-free host bootstrap mrbc (build_config.rb's `host_mrbc` task):
  # what the bc2cpp CI check jobs need, without the whole libmruby (ADR 0228).
  # Not in `all`; never build it concurrently with mruby_build (same build dir).
  add_custom_target(
    mruby_host_mrbc
    COMMAND ${mruby_rake_command} host_mrbc
    WORKING_DIRECTORY "${mruby_prefix}")

  # Expose the computed paths and final rake options to the caller for anything
  # downstream that needs them: root CMakeLists.txt's emscripten-only onigmo
  # re-archiving step and ADDITIONAL_CLEAN_FILES key off MRUBY_BUILD_DIR, and
  # its `rake test` CTest target re-runs rake with the same
  # MRUBY_PREFIX/MRB_OPTS this function just used to build.
  set(MRUBY_BUILD_DIR
      "${mruby_build_dir}"
      PARENT_SCOPE)
  set(LIBMRUBY_A
      "${libmruby_a}"
      PARENT_SCOPE)
  set(MRUBY_PREFIX
      "${mruby_prefix}"
      PARENT_SCOPE)
  set(MRB_OPTS
      "${mrb_opts}"
      PARENT_SCOPE)
endfunction()
