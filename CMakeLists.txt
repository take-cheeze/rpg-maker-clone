cmake_minimum_required(VERSION 3.10)

if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE RelWithDebInfo)
endif()

project(rpg_maker_clone C CXX)

if(EMSCRIPTEN)
  # Emscripten ships SDL2 and SDL2_mixer as "ports": -sUSE_SDL=2 /
  # -sUSE_SDL_MIXER=2 provide both the headers (needed while compiling lvgl's
  # SDL driver and the audio backend) and the libraries at link time.
  #
  # The port compiles one decoder per requested format and defaults to
  # SDL2_MIXER_FORMATS=["ogg"] — WAV is unconditional, everything else is
  # opt-in. So a stock -sUSE_SDL_MIXER=2 build has no MIDI decoder at all, and a
  # .mid would stay silent no matter how the synthesiser is configured. Adding
  # "mid" builds the port with -DMUSIC_MID_TIMIDITY, i.e. the same TiMidity
  # codec the native build uses (tools/ports/sdl2_mixer.py upstream). It needs a
  # patch set to make sound: see WASM_MIDI_PATCHES below. Must be set for both
  # compile and link, as the setting is [compile+link].
  add_compile_options("-sUSE_SDL=2" "-sUSE_SDL_MIXER=2"
                      "-sSDL2_MIXER_FORMATS=ogg,mid")
  add_link_options("-sUSE_SDL=2" "-sUSE_SDL_MIXER=2"
                   "-sSDL2_MIXER_FORMATS=ogg,mid")
  # mruby is built with MRB_USE_CXX_EXCEPTION and throws real C++ exceptions for
  # its internal control flow, so exception support must be enabled across the
  # whole binary; otherwise the first throw aborts in the catch machinery.
  add_compile_options("-fexceptions")
  add_link_options("-fexceptions")
  # Provide a stand-in for the SDL2::SDL2 target the executable links against;
  # the ports above supply the real symbols. SDL2_mixer is linked via
  # ${SDL2_MIXER_LIB}, left empty here as the -sUSE_SDL_MIXER port covers it.
  add_library(SDL2::SDL2 INTERFACE IMPORTED)
  set(SDL2_MIXER_LIB "")
else()
  find_package(SDL2 REQUIRED)
  # SDL2_mixer 2.6+ ships a CMake config exporting SDL2_mixer::SDL2_mixer; fall
  # back to its pkg-config module (e.g. under the nix build) when it does not.
  find_package(SDL2_mixer QUIET)
  if(TARGET SDL2_mixer::SDL2_mixer)
    set(SDL2_MIXER_LIB SDL2_mixer::SDL2_mixer)
  else()
    find_package(PkgConfig REQUIRED)
    pkg_check_modules(SDL2_MIXER REQUIRED IMPORTED_TARGET SDL2_mixer)
    set(SDL2_MIXER_LIB PkgConfig::SDL2_MIXER)
  endif()
endif()

# Seed the toolchain probe results before any subproject can probe for them. The
# wasm configure is otherwise ~110s, almost all of it nested try_compile
# projects run by ng-log/gflags/quickjs/lvgl under emcc; the file supplies the
# answers a real Emscripten configure produced, and gates itself on the
# Emscripten version so a toolchain bump falls back to probing rather than
# reusing values that no longer apply. Must stay above the add_subdirectory
# calls below -- a check_* macro only skips when its result is already cached.
#
# -DEMSCRIPTEN_PROBE_CACHE=OFF runs the probes for real instead, which is how
# scripts/check_emscripten_probe_cache.bash gets a second opinion to diff the
# seeded answers against.
option(EMSCRIPTEN_PROBE_CACHE
       "Seed the Emscripten toolchain probe results instead of running them" ON)
if(EMSCRIPTEN AND EMSCRIPTEN_PROBE_CACHE)
  include(${CMAKE_CURRENT_SOURCE_DIR}/cmake/emscripten-probe-cache.cmake)
endif()

include_directories(${CMAKE_CURRENT_SOURCE_DIR}/include)
# LVGL looks for lv_conf.h at the top-level project directory by default; ours
# lives under include/, so point LVGL's build at that directory explicitly.
set(LV_BUILD_CONF_DIR
    ${CMAKE_CURRENT_SOURCE_DIR}/include
    CACHE PATH "lv_conf.h location" FORCE)
add_subdirectory(3rd/lvgl EXCLUDE_FROM_ALL)

set(WITH_GTEST OFF)
set(WITH_GFLAGS
    OFF
    CACHE BOOL "" FORCE)
set(BUILD_STATIC_LIBS
    ON
    CACHE BOOL "" FORCE)
set(old_build_testing ${BUILD_TESTING})
set(BUILD_TESTING OFF)
add_subdirectory(3rd/gflags EXCLUDE_FROM_ALL)
add_subdirectory(3rd/ng-log EXCLUDE_FROM_ALL)
set(BUILD_TESTING ${old_build_testing})

add_subdirectory(3rd/uni-algo EXCLUDE_FROM_ALL)

# quickjs-ng: the embedded JavaScript engine for RPG Maker MV support (see
# docs/adr/0004-javascript-maker-mv-quickjs.md). Only the `qjs` static library
# is needed — linking it also carries quickjs's own include directory and its
# libm/pthreads dependencies transitively. Its CLI, examples, install rules and
# tests are turned off so add_subdirectory only builds the library.
set(QJS_ENABLE_INSTALL
    OFF
    CACHE BOOL "" FORCE)
set(QJS_BUILD_EXAMPLES
    OFF
    CACHE BOOL "" FORCE)
set(old_build_testing ${BUILD_TESTING})
set(BUILD_TESTING OFF)
add_subdirectory(3rd/quickjs EXCLUDE_FROM_ALL)
set(BUILD_TESTING ${old_build_testing})

# EGL (surfaceless) + GLES2 back the RPG Maker MZ WebGL renderer
# (mruby-mvjs/src/mvgl.cxx, ADR 0004 M6.3). A surfaceless EGL context renders
# through llvmpipe into an FBO with no GPU or display, matching the software
# LVGL pipeline. This is optional: where the libraries are absent (Emscripten
# uses the browser's WebGL; a build without them, e.g. darwin) mvgl.cxx compiles
# to inert stubs (its __has_include guard), so we only link them when found
# rather than REQUIRE them. The apt and nix builds both provide them.
set(GL_LIBS "")
if(NOT EMSCRIPTEN)
  # Plain find_library resolves the libraries on apt (they sit in the system
  # linker path). Under nix they live in per-package store paths find_library
  # doesn't search, so fall back to pkg-config — egl.pc and glesv2.pc from
  # libglvnd, both exposed on nix's PKG_CONFIG_PATH. mvgl.o is compiled with the
  # real backend wherever the headers are present, so whenever that happens the
  # link must find the libraries here too; the two discovery paths keep the
  # header probe and the link in agreement on both toolchains.
  find_library(EGL_LIB EGL)
  find_library(GLESV2_LIB GLESv2)
  if(EGL_LIB AND GLESV2_LIB)
    set(GL_LIBS ${EGL_LIB} ${GLESV2_LIB})
  else()
    find_package(PkgConfig QUIET)
    if(PkgConfig_FOUND)
      pkg_check_modules(EGL IMPORTED_TARGET egl)
      pkg_check_modules(GLESV2 IMPORTED_TARGET glesv2)
      if(TARGET PkgConfig::EGL AND TARGET PkgConfig::GLESV2)
        set(GL_LIBS PkgConfig::EGL PkgConfig::GLESV2)
      endif()
    endif()
  endif()
endif()

set(MRUBY_PREFIX "${CMAKE_CURRENT_SOURCE_DIR}/3rd/mruby")
add_library(mruby STATIC IMPORTED)
set(MRUBY_BUILD_DIR "${CMAKE_CURRENT_BINARY_DIR}/mruby")
if(EMSCRIPTEN)
  # The native "host" build only produces mrbc; the app links the cross build.
  set(MRUBY_TARGET_NAME "emscripten")
  # mruby-onig-regexp normally extracts onigmo's objects into libmruby.a, but
  # under emscripten that fails: the bundled onigmo builds its libonigmo.a with
  # a host ranlib whose symbol table llvm-ar/wasm-ld cannot read (bulk
  # extraction fails on the "/" member and produces corrupt objects). The
  # pristine per-file wasm objects are still emitted next to the archive, so
  # re-archive those with emar and link the result. Version tracks the pin in
  # 3rd/mruby-onig-regexp/mrbgem.rake.
  set(ONIGMO_DIR
      "${MRUBY_BUILD_DIR}/emscripten/mrbgems/mruby-onig-regexp/onigmo-6.2.0")
  set(ONIGMO_A "${CMAKE_CURRENT_BINARY_DIR}/libonigmo_clean.a")
else()
  set(MRUBY_TARGET_NAME "host")
endif()
set(LIBMRUBY_A "${MRUBY_BUILD_DIR}/${MRUBY_TARGET_NAME}/lib/libmruby.a")
set_target_properties(mruby PROPERTIES IMPORTED_LOCATION "${LIBMRUBY_A}")
list(APPEND ADDITIONAL_CLEAN_FILES "${MRUBY_BUILD_DIR}")
# mruby 4.0 always enables presym, so <mruby.h> unconditionally pulls in
# <mruby/presym.h> and its generated mruby/presym/id.h. That header lives in the
# build tree (produced by the mruby build below), not in the source include dir,
# so expose it too. Create it now so CMake's imported-target check — which
# requires INTERFACE include dirs to exist at configure time — passes before the
# build populates it.
set(MRUBY_GEN_INCLUDE "${MRUBY_BUILD_DIR}/${MRUBY_TARGET_NAME}/include")
file(MAKE_DIRECTORY "${MRUBY_GEN_INCLUDE}")
target_include_directories(mruby INTERFACE "${MRUBY_PREFIX}/include"
                                           "${MRUBY_GEN_INCLUDE}")
# Collect the source of each local mrbgem so libmruby.a rebuilds when any of it
# changes. GLOB_RECURSE also picks up files in nested subdirectories, and
# CONFIGURE_DEPENDS makes CMake re-run the glob at build time: adding or
# removing a source file triggers a reconfigure (and thus a libmruby rebuild) on
# the next `make`, with no manual `cmake` re-run. Header changes under src/ are
# caught too so an edit to a private header still forces the archive to be
# rebuilt.
foreach(g mruby-rgss mruby-lcf mruby-rpg2k mruby-rpgxp mruby-rpgvx mruby-mvjs)
  file(
    GLOB_RECURSE
    src
    CONFIGURE_DEPENDS
    ${CMAKE_CURRENT_SOURCE_DIR}/${g}/src/*.c
    ${CMAKE_CURRENT_SOURCE_DIR}/${g}/src/*.cxx
    ${CMAKE_CURRENT_SOURCE_DIR}/${g}/src/*.cpp
    ${CMAKE_CURRENT_SOURCE_DIR}/${g}/src/*.h
    ${CMAKE_CURRENT_SOURCE_DIR}/${g}/src/*.hpp
    ${CMAKE_CURRENT_SOURCE_DIR}/${g}/src/*.hxx)
  file(GLOB_RECURSE rb CONFIGURE_DEPENDS
       ${CMAKE_CURRENT_SOURCE_DIR}/${g}/mrblib/*.rb)
  list(APPEND MRB_FILES ${src} ${rb}
       ${CMAKE_CURRENT_SOURCE_DIR}/${g}/mrbgem.rake)
endforeach()

# Also rebuild libmruby.a when mruby's own core changes. These sources live in
# the 3rd/mruby submodule; CONFIGURE_DEPENDS keeps the list current as the
# submodule is checked out or updated to a new revision.
file(
  GLOB_RECURSE
  mruby_core
  CONFIGURE_DEPENDS
  ${MRUBY_PREFIX}/src/*.c
  ${MRUBY_PREFIX}/src/*.h
  ${MRUBY_PREFIX}/mrblib/*.rb
  ${MRUBY_PREFIX}/include/*.h)
list(APPEND MRB_FILES ${mruby_core})
set(MRB_OPTS
    MRUBY_CONFIG=${CMAKE_CURRENT_SOURCE_DIR}/build_config.rb
    MRUBY_BUILD_DIR=${MRUBY_BUILD_DIR}
    BUILD_DIR=${MRUBY_BUILD_DIR}
    PROJECT_BUILD_DIR=${CMAKE_CURRENT_BINARY_DIR}
    "CXX=${CMAKE_CXX_COMPILER_LAUNCHER} ${CMAKE_CXX_COMPILER}"
    "CC=${CMAKE_C_COMPILER_LAUNCHER} ${CMAKE_C_COMPILER}"
    "CXXFLAGS=${CMAKE_CXX_FLAGS}"
    "CFLAGS=${CMAKE_C_FLAGS}"
    "LDFLAGS=${CMAKE_CXX_FLAGS}")
if(EMSCRIPTEN)
  # Tell build_config.rb to emit the emscripten cross build, and give it native
  # compilers to build mrbc with (CC/CXX above point at emcc/em++).
  list(APPEND MRB_OPTS MRUBY_TARGET=emscripten "HOST_CC=cc" "HOST_CXX=c++")
endif()
# Point mruby's rake at the vendored mgem-list (the mgem index) via symlinks in
# its repos/ dir so it resolves gems locally instead of cloning from GitHub. Use
# `ln -sfn`, not `ln -sf`: once these links exist, a plain `ln -sf` would
# dereference the existing symlink-to-directory and drop a new link *inside*
# 3rd/mgem-list (a self-referential 3rd/mgem-list/mgem-list), dirtying the
# submodule. `-n` (no-dereference; portable across GNU and BSD/macOS) replaces
# the symlink in place instead.
add_custom_command(
  OUTPUT "${LIBMRUBY_A}"
  COMMAND
    mkdir -p ${MRUBY_BUILD_DIR}/repos/host
    ${MRUBY_BUILD_DIR}/repos/${MRUBY_TARGET_NAME} && ln -sfn
    ${CMAKE_CURRENT_SOURCE_DIR}/3rd/mgem-list
    ${MRUBY_BUILD_DIR}/repos/host/mgem-list && ln -sfn
    ${CMAKE_CURRENT_SOURCE_DIR}/3rd/mgem-list
    ${MRUBY_BUILD_DIR}/repos/${MRUBY_TARGET_NAME}/mgem-list && ${MRB_OPTS} rake
    -v
  WORKING_DIRECTORY "${MRUBY_PREFIX}"
  DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/build_config.rb" ${MRB_FILES})
add_custom_target(mruby_build DEPENDS "${LIBMRUBY_A}")
add_dependencies(mruby mruby_build)

if(EMSCRIPTEN)
  # Re-archive onigmo's pristine per-file wasm objects (see ONIGMO_A above).
  # Depend on the mruby_build TARGET, not the ${LIBMRUBY_A} file: a file-level
  # DEPENDS makes CMake copy the libmruby.a recipe into onigmo_clean.dir too, so
  # `make -j` runs rake twice concurrently and the two runs corrupt onigmo's
  # generated config.status. A target dependency just orders us after it.
  add_custom_command(
    OUTPUT "${ONIGMO_A}"
    COMMAND
      sh -c
      "${CMAKE_AR} crs '${ONIGMO_A}' $(find '${ONIGMO_DIR}' -name '*.o' -not -path '*/.libs/*')"
    DEPENDS mruby_build
    VERBATIM)
  add_custom_target(onigmo_clean DEPENDS "${ONIGMO_A}")
endif()

add_executable(${PROJECT_NAME} src/main.cxx src/sdl_input.cxx src/sdl_audio.cxx
                               src/log_console.cxx src/error_dump.cxx)
target_link_libraries(
  ${PROJECT_NAME}
  mruby
  lvgl
  ng-log::ng-log
  SDL2::SDL2
  ${SDL2_MIXER_LIB}
  gflags
  uni-algo::uni-algo
  qjs
  ${GL_LIBS})
target_include_directories(${PROJECT_NAME}
                           PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/3rd/inicpp)

# Stamp the build into the binary so a crash report says which build produced it
# (src/error_dump.cxx). Read at configure time, not build time: a report that
# names the commit the tree was configured at is enough to place a failure, and
# re-running git on every build would rebuild the world on every commit. CI
# configures a fresh checkout per run, so its reports name the exact commit.
find_package(Git QUIET)
set(RPG_BUILD_REVISION "unknown")
if(GIT_FOUND AND EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/.git")
  execute_process(
    COMMAND ${GIT_EXECUTABLE} describe --always --dirty --abbrev=12
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    OUTPUT_VARIABLE RPG_GIT_DESCRIBE
    OUTPUT_STRIP_TRAILING_WHITESPACE ERROR_QUIET)
  if(RPG_GIT_DESCRIBE)
    set(RPG_BUILD_REVISION "${RPG_GIT_DESCRIBE}")
  endif()
endif()
target_compile_definitions(
  ${PROJECT_NAME} PRIVATE "RPG_BUILD_REVISION=\"${RPG_BUILD_REVISION}\""
                          "RPG_BUILD_TYPE=\"${CMAKE_BUILD_TYPE}\"")

# MIDI instruments for SDL_mixer's built-in TiMidity synthesiser. A .mid holds
# note events only, so without a GUS patch set MIDI music loads and then plays
# silence. The patches are ~32 MiB of samples, so they are downloaded by
# scripts/download-freepats.bash rather than committed.
#
# The path is baked in unconditionally and probed at run time (sdl_audio.cxx),
# never tested here: the download is independent of the configure, so a
# configure-time EXISTS check would freeze whichever order they happened to run
# in and force a re-configure on anyone who built before fetching.
set(TIMIDITY_ASSET_DIR ${CMAKE_CURRENT_SOURCE_DIR}/assets/timidity)
target_compile_definitions(
  ${PROJECT_NAME}
  PRIVATE "RGSS_TIMIDITY_CFG_SOURCE=\"${TIMIDITY_ASSET_DIR}/timidity.cfg\"")

if(EMSCRIPTEN)
  # Emit a runnable page (index.html + .js + .wasm) with a growable heap so the
  # interpreter and game assets fit.
  set_target_properties(${PROJECT_NAME} PROPERTIES SUFFIX ".html" OUTPUT_NAME
                                                                  "index")
  add_dependencies(${PROJECT_NAME} onigmo_clean)
  # Browser-only shim exporting Module._rgss_wasm_key, used by the on-screen
  # keypad in the shell page below to feed RGSS::Input.
  target_sources(${PROJECT_NAME} PRIVATE src/wasm_keypad.cxx)
  target_link_options(
    ${PROJECT_NAME}
    PRIVATE
    "-sALLOW_MEMORY_GROWTH=1"
    "-sEXIT_RUNTIME=0"
    "-sFORCE_FILESYSTEM=1"
    # mruby recurses deeply during init and unwinds via C++ exceptions; the
    # default 64 KB wasm stack overflows and corrupts memory (surfacing as "null
    # function"/out-of-bounds/signature-mismatch traps), so give it room.
    "-sSTACK_SIZE=8388608"
    # Symbolication: emit index.wasm.map so Chrome resolves wasm frames to
    # file:line in console stack traces (the printed trace text resolves from
    # the map with no base URL needed), and C++ exception throw sites get real
    # stack traces too.
    "-gsource-map"
    # Keep the DWARF debug info OUT of index.wasm. RelWithDebInfo compiles with
    # -g, and left embedded that DWARF pushed index.wasm past Cloudflare Pages'
    # 25 MiB per-file deploy limit (the preview-cloudflare step rejected it);
    # -gsource-map alone does not strip it. -gseparate-dwarf writes the DWARF to
    # a side file (index.debug.wasm, which we do not deploy) instead, so
    # index.wasm carries no DWARF -- it only fed an interactive debugger anyway,
    # not the printed traces above.
    "-gseparate-dwarf"
    # Runtime checks for the browser — verbose assertions, heap-access
    # validation and stack-overflow detection — to catch the mruby init
    # corruption early instead of as an opaque trap.
    "-sEXCEPTION_STACK_TRACES=1"
    "-sASSERTIONS=2"
    "-sSAFE_HEAP=1"
    "-sSTACK_OVERFLOW_CHECK=2"
    # The shell page needs FS + ccall for the runtime loader, and its two
    # KEEPALIVE entry points kept in the JS exports past dead-code elimination:
    # rpg_start_game (start a project unzipped into /game at runtime) and
    # rgss_wasm_key (the on-screen keypad's key bridge).
    "-sEXPORTED_FUNCTIONS=['_main','_rpg_start_game','_rgss_wasm_key','_malloc','_free']"
    "-sEXPORTED_RUNTIME_METHODS=['ccall','cwrap','FS']"
    # Custom page (src/shell.html): a canvas with an on-screen keypad plus a
    # loader that fetches/opens a zip or GitHub-hosted RPG2k project and mounts
    # it under /game.
    "--shell-file=${CMAKE_CURRENT_SOURCE_DIR}/src/shell.html"
    "${ONIGMO_A}")
  # Relink the page when the shell changes (CMake does not track the
  # --shell-file input on its own).
  set_target_properties(
    ${PROJECT_NAME} PROPERTIES LINK_DEPENDS
                               ${CMAKE_CURRENT_SOURCE_DIR}/src/shell.html)

  # Optionally bake a game directory into the virtual filesystem at /game so the
  # page runs a real game with no interaction. Pass
  # -DWASM_GAME_DIR=/abs/path/to/game at configure time; then main() auto-starts
  # it. Without it, the page waits for the loader to supply a project.
  if(WASM_GAME_DIR)
    file(REAL_PATH ${WASM_GAME_DIR} WASM_GAME_DIR)
    target_link_options(${PROJECT_NAME} PRIVATE
                        "--preload-file=${WASM_GAME_DIR}@/game")
  endif()

  # Optionally bundle an extra, ready-to-run project into the virtual filesystem
  # at /game_sample *without* auto-starting it, so the shell page can offer it
  # as a one-click preset (see src/shell.html) while its loader still handles
  # other projects. Used to ship the committed MV sample (data/mv-sample, with
  # its fetched engine) in the deployed/preview page. Generates index.data.
  if(WASM_SAMPLE_DIR)
    file(REAL_PATH ${WASM_SAMPLE_DIR} WASM_SAMPLE_DIR)
    target_link_options(${PROJECT_NAME} PRIVATE
                        "--preload-file=${WASM_SAMPLE_DIR}@/game_sample")
  endif()

  # Mount the MIDI patch set at /timidity, where src/sdl_audio.cxx looks for it.
  # The TiMidity decoder above is only half of MIDI playback; without these
  # instrument samples a .mid still plays silence in the browser.
  #
  # Off by default because FreePats adds ~32 MiB to index.data, which is a lot
  # for a web page whose games are mostly OGG. Turn on with
  # -DWASM_MIDI_PATCHES=ON, having run scripts/download-freepats.bash.
  #
  # Deliberately not guarded on the directory existing, matching WASM_SAMPLE_DIR
  # above: the download runs concurrently with this configure and is awaited
  # before the link, so a configure-time check would race it.
  option(WASM_MIDI_PATCHES "Preload the MIDI patch set into the wasm build" OFF)
  if(WASM_MIDI_PATCHES)
    target_link_options(${PROJECT_NAME} PRIVATE
                        "--preload-file=${TIMIDITY_ASSET_DIR}@/timidity")
  endif()
endif()

install(TARGETS ${PROJECT_NAME} RUNTIME)

# Ship the MIDI patch set beside the binary so an installed build keeps working
# without the source tree. src/sdl_audio.cxx probes <exe>/../share/... for it.
if(NOT EMSCRIPTEN AND EXISTS ${TIMIDITY_ASSET_DIR}/timidity.cfg)
  include(GNUInstallDirs)
  install(DIRECTORY ${TIMIDITY_ASSET_DIR}/
          DESTINATION ${CMAKE_INSTALL_DATADIR}/rpg-maker-clone/timidity)
endif()

enable_testing()

if(NOT EMSCRIPTEN)
  add_test(
    NAME mruby_test
    COMMAND env ${MRB_OPTS} rake test
    WORKING_DIRECTORY "${MRUBY_PREFIX}")

  # A patch missing from the downloaded set is silent at run time (TiMidity just
  # drops that instrument), so check the config against the files. The script
  # skips cleanly when the patches were never downloaded, so this is registered
  # unconditionally and stays honest either way.
  add_test(
    NAME timidity_patches
    COMMAND ruby ${CMAKE_CURRENT_SOURCE_DIR}/scripts/check_timidity_patches.rb
            ${TIMIDITY_ASSET_DIR})

  # The Ruby half of the crash report — the $stderr tee whose ring buffer gives
  # a report its "Recent log" section. Plain Ruby with no mruby dependencies, so
  # it is checked on CRuby here as well as inside the built interpreter by
  # mruby_test, and needs no display.
  add_test(NAME error_report_capture
           COMMAND ruby
                   ${CMAKE_CURRENT_SOURCE_DIR}/scripts/error_report_check.rb)

  set(exe_open_cmd ${CMAKE_CURRENT_BINARY_DIR}/rpg_maker_clone --timeout_ms=100
                   --game_dir ./data/Nepheshel206beta/Nepheshel206Rbeta)
  # The SDL window backend needs a real display. Linux CI runners are headless,
  # so run under a virtual X server (xvfb-run is provided by the dev shell).
  # Older LVGL silently tolerated a failed SDL_CreateWindow; v9.5.0 correctly
  # errors out when no window can be created, which would abort this smoke test.
  #
  # Use a fixed display number rather than `xvfb-run -a`: CI runs this test
  # concurrently with the MV smoke tests, which are also xvfb-run instances, and
  # `-a`'s auto server-number probe is not atomic — concurrent probes can pick
  # the same display, so one Xvfb loses its server and the client dies with an
  # "XIO: fatal IO error". Each concurrent run gets its own reserved number
  # (exe_open=99, render_probe=98, audio_probe=97, MV runs=100..104 in
  # .github/workflows/build.yml) so they can never collide.
  if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
    set(exe_open_cmd xvfb-run --server-num=99
                     "--server-args=-screen 0 640x480x24" ${exe_open_cmd})
  endif()
  add_test(
    NAME exe_open
    COMMAND ${exe_open_cmd}
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR})

  # The RGSS screen effects (Viewport#color, Viewport#tone) are native rendering
  # that mruby_test cannot reach: that binary has no display, so a Viewport
  # cannot even be constructed. This runs the real renderer and *measures* the
  # frame through Graphics.snap_to_bitmap, so the failure mode where the effect
  # code runs and the screen never changes fails a test instead of shipping. It
  # needs no game directory — the probe builds its own sprite (RGSS.effect_probe
  # in mruby-rgss/mrblib/lib.rb).
  set(render_probe_cmd ${CMAKE_CURRENT_BINARY_DIR}/rpg_maker_clone
                       --rgss_effect_probe --width=544 --height=416)
  if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
    set(render_probe_cmd
        xvfb-run --server-num=98 "--server-args=-screen 0 640x480x24"
        ${render_probe_cmd})
  endif()
  add_test(
    NAME render_probe
    COMMAND ${render_probe_cmd}
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR})

  # The audio counterpart: play a sound from a loose file and then out of an
  # encrypted archive, and check both reach the mixer. mruby_test cannot — that
  # binary installs no audio backend, so every Audio call there is a no-op and a
  # broken memory path looks exactly like a working one. See RGSS.audio_probe.
  set(audio_probe_cmd ${CMAKE_CURRENT_BINARY_DIR}/rpg_maker_clone
                      --rgss_audio_probe)
  if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
    set(audio_probe_cmd xvfb-run --server-num=97
                        "--server-args=-screen 0 640x480x24" ${audio_probe_cmd})
  endif()
  add_test(
    NAME audio_probe
    COMMAND ${audio_probe_cmd}
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR})
  # SDL's dummy driver decodes and mixes with no sound card, so this runs on a
  # CI box with no audio device — where Mix_OpenAudio would otherwise fail and
  # leave the backend uninstalled, making the probe untestable rather than
  # failing. It writes its own fixture into the working directory.
  set_tests_properties(audio_probe PROPERTIES ENVIRONMENT
                                              "SDL_AUDIODRIVER=dummy")

  # The crash report end to end, in the real binary: raise a Ruby exception and
  # check the report that comes out still carries the exception, its backtrace,
  # the log captured before it and the run context, and that the file a reporter
  # would attach holds the same text. Nothing else can catch a report that
  # quietly lost a section — by the time one is wanted, the crash has happened.
  # Runs in the build directory, where the probe writes and then removes its
  # report file. Reserved display 96 (see the exe_open note above).
  set(error_dump_cmd ${CMAKE_CURRENT_BINARY_DIR}/rpg_maker_clone
                     --error_dump_probe --error_dump=error-report-probe.md)
  if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
    set(error_dump_cmd xvfb-run --server-num=96
                       "--server-args=-screen 0 640x480x24" ${error_dump_cmd})
  endif()
  add_test(
    NAME error_dump
    COMMAND ${error_dump_cmd}
    WORKING_DIRECTORY ${CMAKE_CURRENT_BINARY_DIR})
endif()
