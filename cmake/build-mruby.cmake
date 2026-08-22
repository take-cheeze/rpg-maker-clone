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
  add_custom_command(
    OUTPUT "${libmruby_a}"
    COMMAND "${ARG_REPO_ROOT}/scripts/apply_mruby_patch.bash" "${mruby_prefix}"
            "${mruby_colon3_patch}"
    COMMAND "${ARG_REPO_ROOT}/scripts/apply_mruby_patch.bash" "${mruby_prefix}"
            "${mruby_dollar_bang_patch}"
    COMMAND
      mkdir -p ${mruby_build_dir}/repos/host
      ${mruby_build_dir}/repos/${ARG_TARGET_NAME} && ln -sfn
      ${ARG_REPO_ROOT}/3rd/mgem-list ${mruby_build_dir}/repos/host/mgem-list &&
      ln -sfn ${ARG_REPO_ROOT}/3rd/mgem-list
      ${mruby_build_dir}/repos/${ARG_TARGET_NAME}/mgem-list && ${mrb_opts} rake
      -v
    WORKING_DIRECTORY "${mruby_prefix}"
    DEPENDS "${ARG_REPO_ROOT}/build_config.rb" "${mruby_colon3_patch}"
            "${mruby_dollar_bang_patch}" ${mrb_files})
  add_custom_target(mruby_build DEPENDS "${libmruby_a}")
  add_dependencies(mruby mruby_build)

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
