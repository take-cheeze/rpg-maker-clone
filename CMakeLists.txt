cmake_minimum_required(VERSION 3.10)

if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE RelWithDebInfo)
endif()

project(rpg_maker_clone C CXX)

# Link with mold instead of the toolchain's default linker (bfd on the nix/apt
# GCC builds) when it's available -- mold is dramatically faster on this
# project's link steps (the main executable plus every 3rd/* static lib and test
# binary). Doesn't apply to Emscripten, which always links through wasm-ld
# regardless of -fuse-ld. check_linker_flag needs CMake 3.18, one above this
# project's 3.10 floor, so an older cmake just skips the upgrade and falls back
# to the default linker instead of failing to configure.
option(USE_MOLD "Link with mold when available" ON)
if(USE_MOLD
   AND NOT EMSCRIPTEN
   AND NOT ANDROID
   AND CMAKE_VERSION VERSION_GREATER_EQUAL 3.18)
  include(CheckLinkerFlag)
  check_linker_flag(CXX "-fuse-ld=mold" CXX_LINKER_SUPPORTS_MOLD)
  if(CXX_LINKER_SUPPORTS_MOLD)
    message(STATUS "Linking with mold")
    add_link_options("-fuse-ld=mold")
  else()
    message(STATUS "mold not available, using the default linker")
  endif()
endif()

# Per-translation-unit compiler-phase timing: GCC's own -ftime-report-details
# prints, for every file it actually compiles (a no-op on an sccache cache
# hit, since sccache then never invokes cc1plus at all), how much wall/user/
# sys time went into each compiler phase and pass -- parsing, template
# instantiation, individual GIMPLE/RTL passes, and so on. Off by default: it's
# diagnostic-only stderr noise a local incremental build has no use for. CI's
# own "build" job (.github/workflows/build.yml) turns it on unconditionally
# via -DENABLE_TIME_REPORT=ON, tees the build log, and feeds it to
# scripts/compile_time_report.rb, which turns these per-file blocks into a
# "slowest files/phases this run" job-summary table -- a standing bottleneck
# hint that costs nothing on a warm cache and only grows informative exactly
# when a run actually recompiles a lot (a cold cache, a submodule bump, a
# change to a widely-included header).
option(ENABLE_TIME_REPORT "Emit GCC's -ftime-report-details compiler-phase timing" OFF)
if(ENABLE_TIME_REPORT)
  if(CMAKE_CXX_COMPILER_ID STREQUAL "GNU")
    include(CheckCXXCompilerFlag)
    check_cxx_compiler_flag("-ftime-report" CXX_SUPPORTS_TIME_REPORT)
    if(CXX_SUPPORTS_TIME_REPORT)
      # -ftime-report-details (GCC 10+) only adds its per-pass breakdown on
      # top of -ftime-report's own per-phase totals -- passed alone it
      # compiles cleanly (so a flag-support check alone can't tell them
      # apart) but emits nothing at all, so -ftime-report itself always goes
      # first and -ftime-report-details is an addition, never a substitute.
      add_compile_options("-ftime-report")
      check_cxx_compiler_flag("-ftime-report-details" CXX_SUPPORTS_TIME_REPORT_DETAILS)
      if(CXX_SUPPORTS_TIME_REPORT_DETAILS)
        add_compile_options("-ftime-report-details")
      endif()
    else()
      message(WARNING "ENABLE_TIME_REPORT requested but this GCC does not support -ftime-report -- no-op")
    endif()
  else()
    message(STATUS "ENABLE_TIME_REPORT requested but the compiler is "
                    "${CMAKE_CXX_COMPILER_ID}, not GCC -- no-op (GCC-only flag)")
  endif()
endif()

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
elseif(ANDROID)
  # Android has no system SDL2/SDL2_mixer package (there is no system linker
  # path an APK's native libs can resolve against at all) -- every SDL2 Android
  # app vendors the source and builds it as part of its own native library, the
  # same way app/android's Gradle project points its CMake build straight at
  # this file. See docs/adr/0058-android-port.md.
  #
  # Both build SHARED (their own CMakeLists.txt default): app/android's Java
  # SDLActivity subclass loads "libSDL2.so" and "libSDL2_mixer.so" before
  # "lib${PROJECT_NAME}.so" (SDLActivity.getLibraries()) -- the same shape as
  # the official SDL android-project template's commented-out SDL2_mixer line.
  # SDL2_mixer's own CMakeLists.txt picks between the SDL2::SDL2 and
  # SDL2::SDL2-static targets to link against based on *its own*
  # BUILD_SHARED_LIBS, so both must build shared together rather than statically
  # linking SDL2_mixer into this project's own library: that would need the
  # SDL2::SDL2-static target, which building SDL2 shared never defines.
  #
  # Force this as a CACHE FORCE, not a plain set(): SDL2_mixer's own
  # CMakeLists.txt declares `option(BUILD_SHARED_LIBS ... ON)`, and option()
  # only seeds a cache entry that doesn't exist yet -- on a from-scratch
  # configure a plain set() here would lose to that option() call once
  # add_subdirectory(3rd/SDL_mixer) below runs, and the *global* default this
  # variable controls (every add_library() below that doesn't say STATIC/SHARED,
  # including lvgl/gflags/ng-log/qjs/uni-algo further down) would stay ON
  # instead of going back OFF afterwards -- confirmed the hard way: a first pass
  # at this left every one of those shared too, nine .so files in the APK
  # instead of the two this comment documents.
  set(BUILD_SHARED_LIBS
      ON
      CACHE BOOL "" FORCE)
  add_subdirectory(3rd/SDL EXCLUDE_FROM_ALL)
  # Match the codec set the Emscripten build ships (see its SDL2_MIXER_FORMATS
  # comment above): OGG Vorbis + MIDI. SDL2_mixer bundles its own stb_vorbis.h
  # and TiMidity decoders directly (src/codecs/{stb_vorbis,timidity}) -- no
  # extra vendoring needed for either, unlike the FLAC/MP3/Opus/MOD/WavPack
  # codecs below, which pull in their own external/ submodules this project does
  # not initialize. Trimming them out keeps the Android native build to the same
  # audio formats every other target already supports, instead of silently
  # growing a second, wider codec matrix only this platform has.
  set(SDL2MIXER_VORBIS
      "STB"
      CACHE STRING "" FORCE)
  set(SDL2MIXER_MIDI_TIMIDITY
      ON
      CACHE BOOL "" FORCE)
  set(SDL2MIXER_FLAC
      OFF
      CACHE BOOL "" FORCE)
  set(SDL2MIXER_MP3
      OFF
      CACHE BOOL "" FORCE)
  set(SDL2MIXER_OPUS
      OFF
      CACHE BOOL "" FORCE)
  set(SDL2MIXER_MOD
      OFF
      CACHE BOOL "" FORCE)
  set(SDL2MIXER_WAVPACK
      OFF
      CACHE BOOL "" FORCE)
  set(SDL2MIXER_GME
      OFF
      CACHE BOOL "" FORCE)
  set(SDL2MIXER_CMD
      OFF
      CACHE BOOL "" FORCE)
  add_subdirectory(3rd/SDL_mixer EXCLUDE_FROM_ALL)
  set(SDL2_MIXER_LIB SDL2_mixer::SDL2_mixer)
  # Back to static for everything below (lvgl, gflags, ng-log, qjs, uni-algo) --
  # matching the desktop build, which links all of those into the single
  # executable rather than shipping each as its own shared object.
  set(BUILD_SHARED_LIBS
      OFF
      CACHE BOOL "" FORCE)
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
# LVGL's CMake builds its examples and demos into the `lvgl` library itself
# (they are PUBLIC-linked), and their sources call widget constructors that
# include/lv_conf.h disables -- so building them would fail to compile. The
# runtime uses none of them, and matching app/psp's EBOOT keeps the configs
# aligned. Set as cache variables so they override LVGL's `option(...)` defaults
# even with CMP0077 unset (see app/psp/CMakeLists.txt).
set(CONFIG_LV_BUILD_EXAMPLES
    OFF
    CACHE BOOL "" FORCE)
set(CONFIG_LV_BUILD_DEMOS
    OFF
    CACHE BOOL "" FORCE)
add_subdirectory(3rd/lvgl EXCLUDE_FROM_ALL)
if(ANDROID)
  # LVGL's own CMakeLists.txt globs its SDL driver sources (src/drivers/sdl/*.c)
  # unconditionally and leans on __has_include(<SDL2/SDL.h>) to opt them in,
  # rather than a find_package or option of its own. That finds SDL2's headers
  # for free on the desktop build -- a system SDL2 install already sits on the
  # compiler's default search path -- but not here, where SDL2 is vendored fresh
  # with no system install at all (see the elseif(ANDROID) block above). Give
  # the lvgl target the real include path (and link it) explicitly -- CMP0079
  # NEW since the `lvgl` target belongs to 3rd/lvgl's own CMakeLists.txt, not
  # this one.
  cmake_policy(SET CMP0079 NEW)
  target_link_libraries(lvgl PUBLIC SDL2::SDL2)
endif()

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
# Drop the Unicode tables for the uni-algo modules nothing here calls -- see
# cmake/uni-algo-trim.cmake for what is kept and why.
include(cmake/uni-algo-trim.cmake)
rpg2k_trim_uni_algo()

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
#
# Android also finds and links both here -- despite mvgl.cxx's own
# !defined(__ANDROID__) guard keeping it off the real EGL desktop path (its
# libEGL.so does not export eglGetPlatformDisplay, unlike the apt/nix Mesa
# builds -- see mvgl.cxx and docs/adr/0058-android-port.md) -- because LVGL's
# own OpenGL ES driver (3rd/lvgl/src/drivers/opengles, compiled unconditionally
# the same __has_include-driven way the SDL driver above is) calls plain GLES2
# entry points (glViewport, glClear, ...) that Android's real libGLESv2.so does
# provide; only the desktop-EGL-1.5-specific symbol was ever missing.
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

# Effekseer's GraphicsDevice.cpp needs the real <GLES3/gl3.h> header (see below)
# -- normally shipped alongside <GLES2/gl2.h> by the same package
# (libgles2-mesa-dev / libglvnd's headers), but not guaranteed, so this is
# probed for separately rather than assumed once GL_LIBS is non-empty.
set(HAVE_GLES3_HEADER FALSE)
if(GL_LIBS)
  # A raw compiler probe, not check_include_file_cxx: CMAKE_REQUIRED_* is global
  # state several of the subprojects add_subdirectory'd above (lvgl, ng-log) run
  # their own checks through without resetting afterward, and by this point in
  # the configure it reliably makes check_include_file_cxx report GLES3/gl3.h
  # absent even when a bare compiler invocation finds it fine.
  # mruby-mvjs/mrbgem.rake's own have_egl probe already uses exactly this
  # direct-compiler-invocation shape for the same header-presence question, one
  # layer down (Ruby's `system` there, CMake's execute_process here) -- same
  # technique, same reason to trust it over the module.
  execute_process(
    COMMAND ${CMAKE_COMMAND} -E echo "#include <GLES3/gl3.h>"
    COMMAND ${CMAKE_CXX_COMPILER} -E -x c++ -
    RESULT_VARIABLE GLES3_HEADER_PROBE_RESULT
    OUTPUT_QUIET ERROR_QUIET)
  if(GLES3_HEADER_PROBE_RESULT EQUAL 0)
    set(HAVE_GLES3_HEADER TRUE)
  endif()
endif()

# Effekseer (github.com/effekseer/Effekseer, MIT, vendored at 3rd/effekseer,
# pinned to release tag 1807): the real particle engine RPG Maker MZ ships as
# `js/libs/effekseer.min.js` for battle animations. Only built where the GL
# backend above is actually available -- Effekseer's own GL renderer needs a
# real GLES context to draw into, the same one mvgl.cxx/mvwebgl.cxx already
# expose, so building it anywhere GL_LIBS is empty (Emscripten, a GL-less host)
# would be dead weight with nothing to link it into.
#
# `add_subdirectory` on the real repo root (not Dev/Cpp directly) matters: the
# root CMakeLists.txt appends its own cmake/ dir to CMAKE_MODULE_PATH and
# `include(FilterFolder)` before descending into Dev -- Dev/Cpp's own
# CMakeLists.txt calls that function unqualified, so skipping straight to
# Dev/Cpp fails configure with "Unknown CMake command "filterfolder"". BUILD_GL
# defaults ON upstream (forced here for clarity, not because the default is
# wrong) and gates `Effekseer`/`EffekseerRendererCommon` (always built) plus
# `EffekseerRendererGL`; every other backend (DX9/11/12, Vulkan, Metal, WebGPU,
# the sound backends) stays off since nothing here sets its BUILD_*/USE_*
# option. BUILD_EXAMPLES/BUILD_TOOLS default ON upstream and are forced off here
# -- left alone they add_subdirectory(Examples)/Tool, each with their own
# dependency surface this build has no use for. USE_OPENGLES3, not 2: mvgl.cxx's
# own GL calls only ever need the ES2 (`<GLES2/gl2.h>`) subset, but the EGL
# context it creates really is ES3 (EGL_CONTEXT_MAJOR_VERSION 3, falling back to
# ES2 only where the driver lacks it -- true on the apt/nix llvmpipe builds this
# targets). Effekseer's own GraphicsDevice.cpp needs real ES3: multiple render
# target attachments (GL_COLOR_ATTACHMENT1-3), VAOs (GL_VERTEX_ARRAY_BINDING),
# and float/half- float texture formats
# (GL_RED/GL_RG/GL_HALF_FLOAT/GL_DEPTH24_STENCIL8), none of which plain ES2
# declares -- USE_OPENGLES2 fails to compile on exactly these symbols.
set(EFFEKSEER_LIBS "")
if(NOT EMSCRIPTEN
   AND GL_LIBS
   AND HAVE_GLES3_HEADER)
  set(BUILD_GL
      ON
      CACHE BOOL "" FORCE)
  set(BUILD_EXAMPLES
      OFF
      CACHE BOOL "" FORCE)
  set(BUILD_TOOLS
      OFF
      CACHE BOOL "" FORCE)
  set(USE_OPENGLES3
      ON
      CACHE BOOL "" FORCE)
  # Effekseer's own sound backends are for engines with no audio pipeline of
  # their own; MZ's real Sound Manager already runs through this project's own
  # WebAudio bridge (mv.rb's AUDIO_BRIDGE_JS), so Effekseer never needs to play
  # anything itself. USE_OPENAL defaults ON on non-MSVC and this sandbox has no
  # OpenAL installed, which without this fails configure outright (Dev/Cpp's
  # CMakeLists.txt add_subdirectory(EffekseerSoundAL)s unconditionally under
  # USE_OPENAL, then set_property()s a target that silently never got created).
  set(USE_OPENAL
      OFF
      CACHE BOOL "" FORCE)
  add_subdirectory(3rd/effekseer EXCLUDE_FROM_ALL)
  # Upstream bug, not ours to fix in the vendored tree: GLExtension.cpp calls
  # eglGetProcAddress whenever __EFFEKSEER_RENDERER_GLES2__/_GLES3__ is defined
  # (the correct way to resolve GL extension procs on any EGL-backed GLES
  # platform), but only #includes <EGL/egl.h> under __ANDROID__ or
  # __EMSCRIPTEN__ -- missing exactly our case, desktop Linux + EGL + GLES.
  # Force-including the header (rather than patching the submodule) keeps the
  # fix entirely in this build's own CMake, since it is a real, narrow gap in a
  # codepath this project actually exercises, not a local patch to carry.
  target_compile_options(EffekseerRendererGL PRIVATE -include EGL/egl.h)
  # Same story, a different two symbols: GraphicsDevice.cpp's B8G8R8A8_UNORM and
  # 32-bit depth-only texture branches reference GL_BGRA and
  # GL_DEPTH_COMPONENT32 unconditionally, but neither is declared by
  # <GLES3/gl3.h> -- they are desktop-GL/extension enums
  # (GL_BGRA_EXT/GL_DEPTH_COMPONENT32_OES have the identical values on every
  # driver, since GLES extensions standardised on the desktop GL numbers).
  # Defining the real numeric constants directly is simpler than routing through
  # the _EXT/_OES spellings and correct either way: this only affects whether
  # the *symbol* resolves at compile time, not whether the driver accepts the
  # enum at runtime, and MZ's own effects use plain RGBA8/D24S8 (mvgl.cxx's own
  # FBO format), never triggering either branch.
  target_compile_definitions(EffekseerRendererGL
                             PRIVATE GL_BGRA=0x80E1 GL_DEPTH_COMPONENT32=0x81A7)
  set(EFFEKSEER_LIBS Effekseer EffekseerRendererCommon EffekseerRendererGL)
endif()

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
  # Tell build_config.rb to emit the emscripten cross build, and give it native
  # compilers to build mrbc with (CXX=/CC= below point at em++/emcc).
  set(MRUBY_EXTRA_OPTS MRUBY_TARGET=emscripten "HOST_CC=cc" "HOST_CXX=c++")
elseif(ANDROID)
  # Same reasoning as the Emscripten branch above: this configure's own
  # CMAKE_C_COMPILER/CMAKE_CXX_COMPILER are the NDK's cross clang (set by
  # android.toolchain.cmake), and the "host" MRuby::Build below -- which only
  # exists to produce the natively-executable mrbc bytecode compiler -- must not
  # use it. HOST_CC/HOST_CXX force it back to the ambient native compiler; the
  # android cross target (build_config.rb) picks up its own NDK clang
  # independently via mruby's built-in :android toolchain
  # (ANDROID_NDK_HOME/ANDROID_ARCH/ANDROID_PLATFORM below), not through
  # CMAKE_CXX_COMPILER at all.
  set(MRUBY_TARGET_NAME "android")
  set(MRUBY_EXTRA_OPTS
      MRUBY_TARGET=android "HOST_CC=cc" "HOST_CXX=c++"
      "ANDROID_NDK_HOME=$ENV{ANDROID_NDK_HOME}" "ANDROID_ARCH=${ANDROID_ABI}"
      "ANDROID_PLATFORM=${ANDROID_NATIVE_API_LEVEL}")
else()
  set(MRUBY_TARGET_NAME "host")
  set(MRUBY_EXTRA_OPTS "")
endif()

# Build libmruby.a via mruby's own rake-based build system (build_config.rb),
# factored into cmake/build-mruby.cmake since the PSP EBOOT build
# (app/psp/CMakeLists.txt) drives the exact same rake invocation with only the
# target name, gem list and a few extra rake options differing.
include(${CMAKE_CURRENT_SOURCE_DIR}/cmake/build-mruby.cmake)
rpg2k_add_mruby(
  TARGET_NAME
  ${MRUBY_TARGET_NAME}
  REPO_ROOT
  ${CMAKE_CURRENT_SOURCE_DIR}
  PROJECT_BUILD_DIR
  ${CMAKE_CURRENT_BINARY_DIR}
  GEMS
  mruby-rgss
  mruby-lcf
  mruby-rpg2k
  mruby-rpgxp
  mruby-rpgvx
  mruby-mvjs
  MRB_OPTS
  BUILD_DIR=${MRUBY_BUILD_DIR}
  "CXX=${CMAKE_CXX_COMPILER_LAUNCHER} ${CMAKE_CXX_COMPILER}"
  "CC=${CMAKE_C_COMPILER_LAUNCHER} ${CMAKE_C_COMPILER}"
  "CXXFLAGS=${CMAKE_CXX_FLAGS}"
  "CFLAGS=${CMAKE_C_FLAGS}"
  "LDFLAGS=${CMAKE_CXX_FLAGS}"
  ${MRUBY_EXTRA_OPTS})
list(APPEND ADDITIONAL_CLEAN_FILES "${MRUBY_BUILD_DIR}")

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

set(RPG_SOURCES
    src/main.cxx
    src/sdl_input.cxx
    src/sdl_audio.cxx
    src/voicevox_tts.cxx
    src/log_console.cxx
    src/log_bridge.cxx
    src/window_title.cxx
    src/error_dump.cxx)
if(ANDROID)
  # SDLActivity (app/android) loads a JNI shared library, not a process it can
  # exec -- Android has no argv-taking process launcher for an app's own native
  # code the way a desktop OS or the PSP's EBOOT loader does. SDL2main's
  # src/main/android/SDL_android_main.c (linked below) is the real JNI entry
  # point Java calls; it forwards into this project's own renamed SDL_main
  # (src/main.cxx's ordinary `int main`, renamed by SDL.h's `#define main
  # SDL_main` on every platform including this one -- see
  # docs/adr/0058-android-port.md).
  add_library(${PROJECT_NAME} SHARED ${RPG_SOURCES})
else()
  add_executable(${PROJECT_NAME} ${RPG_SOURCES})
endif()
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
  ${CMAKE_DL_LIBS}
  ${EFFEKSEER_LIBS}
  ${GL_LIBS})
if(ANDROID)
  target_link_libraries(${PROJECT_NAME} SDL2main log android)
  # Android-only visible virtual-gamepad overlay (src/android_vpad_ui.cxx):
  # draws sdl_input.cxx's touch zones as LVGL widgets on lv_layer_top() so they
  # are discoverable on a phone -- the browser build's counterpart is the shell
  # page's HTML keypad plus src/wasm_keypad.cxx.
  target_sources(${PROJECT_NAME} PRIVATE src/android_vpad_ui.cxx)
endif()
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

# Zundamon (ずんだもん) message-window narration (--zundamon_tts,
# src/voicevox_tts.cxx): a full offline VOICEVOX CORE synthesis stack -- the
# CORE C API library, its ONNX Runtime, the Open JTalk dictionary and Zundamon's
# voice model -- dlopen()'d at run time, never a link-time dependency. ~90 MiB,
# so it is downloaded by scripts/download-voicevox-zundamon.bash rather than
# committed, the same reasoning as the MIDI patch set above; the path is baked
# in unconditionally and probed at run time for the same reason (a
# configure-time EXISTS check would race the download).
set(VOICEVOX_ASSET_DIR ${CMAKE_CURRENT_SOURCE_DIR}/assets/voicevox)
target_compile_definitions(
  ${PROJECT_NAME} PRIVATE "RGSS_VOICEVOX_SOURCE_DIR=\"${VOICEVOX_ASSET_DIR}\"")

# The default UI font, used when a project ships no font of its own -- otherwise
# its windows draw with the fixed 12px shinonome bitmap font whatever size they
# asked for. ~1.7 MiB, so it is downloaded by scripts/download-default-font.bash
# rather than committed.
#
# Both paths are baked in unconditionally and probed at run time (src/main.cxx,
# init_default_font), for the same reason as the patch set above: a
# configure-time EXISTS check would race the download.
include(GNUInstallDirs)
set(DEFAULT_FONT_ASSET_DIR ${CMAKE_CURRENT_SOURCE_DIR}/assets/fonts)
target_compile_definitions(
  ${PROJECT_NAME}
  PRIVATE
    "RGSS_DEFAULT_FONT_SOURCE_DIR=\"${DEFAULT_FONT_ASSET_DIR}\""
    "RGSS_DEFAULT_FONT_INSTALL_DIR=\"${CMAKE_INSTALL_FULL_DATADIR}/rpg-maker-clone/fonts\""
)

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
    # SAFE_HEAP=2, not 1: mode 2 keeps the out-of-bounds and null heap-access
    # checks and downgrades the alignment check to a one-shot warning. Mode 1
    # aborts on it, and that killed the page at startup -- "Aborted(alignment
    # fault)" out of JS_CallInternal, before any game code ran. The unaligned
    # access is quickjs's: a JSFunctionBytecode's constant pool is laid out
    # directly behind the struct (cpool_offset = sizeof(*b)), and that struct is
    # 92 bytes on wasm32 -- 4-byte aligned, being all 32-bit fields -- so the
    # JSValue array behind it starts 4 bytes off its natural 8-byte alignment.
    # Every OP_fclosure/OP_push_const load from it trips the check, so any
    # script holding a nested function does, our own host preamble
    # (mruby-mvjs/src/mvjs.cxx) included. Only mode 1's strictness is lost:
    # unaligned accesses are legal in wasm, and mode 1 rejects them so that a
    # build stays valid through wasm2js as well, which this page never uses. A
    # single "warning: alignment fault" line in a page log is that check, and is
    # expected rather than a symptom.
    "-sSAFE_HEAP=2"
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
  # instrument samples the browser does not merely play a .mid quietly, it fails
  # to load one at all ("Couldn't open timidity.cfg"), so an RPG2000 project --
  # whose BGM is nearly all .mid -- runs silent.
  #
  # These do NOT go through --preload-file, which would fold them into the one
  # index.data and push it past Cloudflare Pages' 25 MiB per-file limit, where
  # `/preview` deploys. scripts/pack-timidity-data.py splits them across as many
  # timidity*.data packages as the budget needs and emits a single timidity.js
  # loader for them, which src/shell.html pulls in ahead of the runtime script.
  # See ADR 0031.
  #
  # Three settings, because the two callers want opposite things:
  #
  # * AUTO (the default) packages the patches once
  #   scripts/download-freepats.bash has installed them. This is the local flow
  #   -- fetch, configure, and the page plays MIDI -- and skipping the download
  #   still gives a page ~32 MiB lighter, with the configure saying so instead
  #   of leaving it to be found as silence.
  # * ON packages whether or not the directory is there yet, which is what CI
  #   needs: it fetches the patches in a background step running *alongside*
  #   this configure, awaited by a barrier before the build, so a configure-time
  #   EXISTS check would race the download and lose. WASM_SAMPLE_DIR above has
  #   the same shape for the same reason.
  # * OFF never packages, for a deliberately slim page.
  #
  # AUTO reads the directory at configure time, so a download landing after this
  # ran needs a re-configure to be seen -- which is exactly why CI passes ON.
  set(WASM_MIDI_PATCHES
      "AUTO"
      CACHE STRING
            "Package the MIDI patch set into the wasm build: AUTO, ON or OFF")
  set_property(CACHE WASM_MIDI_PATCHES PROPERTY STRINGS AUTO ON OFF)
  string(TOUPPER "${WASM_MIDI_PATCHES}" wasm_midi_patches_mode)
  if(wasm_midi_patches_mode STREQUAL "AUTO")
    if(EXISTS ${TIMIDITY_ASSET_DIR}/timidity.cfg)
      set(wasm_midi_patches ON)
    else()
      set(wasm_midi_patches OFF)
      message(
        STATUS
          "MIDI: ${TIMIDITY_ASSET_DIR} is empty, so this page will not play "
          ".mid BGM/ME at all. Run scripts/download-freepats.bash and "
          "re-configure, or pass -DWASM_MIDI_PATCHES=ON to package it "
          "regardless (the build then requires the directory to exist).")
    endif()
  elseif(wasm_midi_patches_mode MATCHES "^(ON|OFF|TRUE|FALSE|YES|NO|1|0)$")
    set(wasm_midi_patches ${wasm_midi_patches_mode})
  else()
    # An unrecognised value must not quietly mean "off": that is the failure
    # this setting exists to prevent.
    message(FATAL_ERROR "WASM_MIDI_PATCHES must be AUTO, ON or OFF, not "
                        "'${WASM_MIDI_PATCHES}'")
  endif()

  # timidity.js is generated either way: with the patches off it is a comment
  # saying so, which keeps src/shell.html's script tag unconditional rather than
  # leaving a 404 on every slim build. The packages themselves are ordinary
  # build outputs, so they are produced by a target the page depends on, well
  # after CI's download barrier.
  find_package(Python3 REQUIRED COMPONENTS Interpreter)
  get_filename_component(EMSCRIPTEN_TOOLS "${EMSCRIPTEN_ROOT_PATH}/tools"
                         ABSOLUTE)
  set(TIMIDITY_LOADER "${CMAKE_CURRENT_BINARY_DIR}/timidity.js")
  if(wasm_midi_patches)
    set(timidity_pack_input ${TIMIDITY_ASSET_DIR})
  else()
    # A path that cannot exist: the packer then writes only the "no patches"
    # loader, with no branch of its own for the disabled case.
    set(timidity_pack_input "${CMAKE_CURRENT_BINARY_DIR}/no-timidity-patches")
  endif()
  add_custom_command(
    OUTPUT ${TIMIDITY_LOADER}
    COMMAND
      ${Python3_EXECUTABLE}
      ${CMAKE_CURRENT_SOURCE_DIR}/scripts/pack-timidity-data.py
      ${timidity_pack_input} ${CMAKE_CURRENT_BINARY_DIR} --file-packager
      ${EMSCRIPTEN_TOOLS}/file_packager.py
    DEPENDS ${CMAKE_CURRENT_SOURCE_DIR}/scripts/pack-timidity-data.py
    COMMENT "Packaging the MIDI patch set for the browser"
    VERBATIM)
  add_custom_target(timidity_data DEPENDS ${TIMIDITY_LOADER})
  add_dependencies(${PROJECT_NAME} timidity_data)
  list(APPEND ADDITIONAL_CLEAN_FILES ${TIMIDITY_LOADER})

  # Mount the default UI font at /fonts, where the text renderer looks for it
  # (mruby-rgss/src/default_font.cxx). Without it, an XP/VX/MV project that
  # ships no font of its own draws its windows with the 12px bitmap font in the
  # browser, however large the text was meant to be.
  #
  # Off by default, like the patch set: emcc fails the link when the preloaded
  # directory is missing, and it is missing until the download has been run.
  # Turn on with -DWASM_DEFAULT_FONT=ON, having run
  # scripts/download-default-font.bash. Adds ~1.7 MiB to index.data.
  option(WASM_DEFAULT_FONT "Preload the default UI font into the wasm build"
         OFF)
  if(WASM_DEFAULT_FONT)
    target_link_options(${PROJECT_NAME} PRIVATE
                        "--preload-file=${DEFAULT_FONT_ASSET_DIR}@/fonts")
  endif()
endif()

# Android's Gradle build never runs `cmake --install` -- externalNativeBuild
# copies the built .so into the APK itself -- and a SHARED library target needs
# the LIBRARY, not RUNTIME, keyword to install correctly on a non-Windows
# platform, so skip the whole install() surface below rather than have it
# silently do the wrong thing for anyone who does invoke it by hand.
if(NOT ANDROID)
  install(TARGETS ${PROJECT_NAME} RUNTIME)
endif()

# Ship the MIDI patch set beside the binary so an installed build keeps working
# without the source tree. src/sdl_audio.cxx probes <exe>/../share/... for it.
if(NOT EMSCRIPTEN
   AND NOT ANDROID
   AND EXISTS ${TIMIDITY_ASSET_DIR}/timidity.cfg)
  include(GNUInstallDirs)
  install(DIRECTORY ${TIMIDITY_ASSET_DIR}/
          DESTINATION ${CMAKE_INSTALL_DATADIR}/rpg-maker-clone/timidity)
endif()

# Same for the default UI font, which src/main.cxx probes for at
# RGSS_DEFAULT_FONT_INSTALL_DIR. OFL.txt sits in the same directory and is
# installed with it, as the licence requires.
if(NOT EMSCRIPTEN
   AND NOT ANDROID
   AND EXISTS ${DEFAULT_FONT_ASSET_DIR})
  include(GNUInstallDirs)
  install(
    DIRECTORY ${DEFAULT_FONT_ASSET_DIR}/
    DESTINATION ${CMAKE_INSTALL_DATADIR}/rpg-maker-clone/fonts
    FILES_MATCHING
    PATTERN "*.ttf"
    PATTERN "*.otf"
    PATTERN "*.ttc"
    PATTERN "OFL.txt")
endif()

enable_testing()

# These ctests all exec the just-built ${PROJECT_NAME} (or mruby's own rake test
# binaries) directly on the machine running the configure -- fine for the
# desktop build, meaningless for Emscripten (a browser runtime, not a host
# executable) and for Android (an ARM/x86 .so a Gradle/Java host can't exec
# either; the closest equivalent would be an instrumented run under adb/an
# emulator, not wired up here -- see docs/adr/0058-android-port.md).
if(NOT EMSCRIPTEN AND NOT ANDROID)
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

  # A default font that is truncated, or subsetted down to Latin, is silent in
  # the same way: stb_truetype draws nothing for the glyphs it cannot find, so
  # the failure arrives as blank window text. Check the file instead. Skips
  # cleanly when the font was never downloaded, so this too is registered
  # unconditionally.
  add_test(
    NAME default_font
    COMMAND ruby ${CMAKE_CURRENT_SOURCE_DIR}/scripts/check_default_font.rb
            ${DEFAULT_FONT_ASSET_DIR})

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
  set(render_probe_cmd ${CMAKE_CURRENT_BINARY_DIR}/rpg_maker_clone --test_play
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
  set(audio_probe_cmd ${CMAKE_CURRENT_BINARY_DIR}/rpg_maker_clone --test_play
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
  set(error_dump_cmd ${CMAKE_CURRENT_BINARY_DIR}/rpg_maker_clone --test_play
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
