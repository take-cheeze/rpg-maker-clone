# Standalone pspdev CMake project for the PSP EBOOT -- HAL bring-up.
#
# This is additive to and independent of the desktop CMake build at the repo
# root: it is a separate project rooted here, mirroring how platformio.ini keeps
# the Wio firmware separate. Building it does not touch the desktop/wasm builds,
# and vice versa. See app/psp/README.md and docs/adr/0010-psp-port.md.
#
# It requires the pspdev toolchain (https://github.com/pspdev/pspdev), which
# provides psp-gcc and the CMake toolchain file plus the create_pbp_file macro.
# Configure with psp-cmake (or plain cmake with
# -DCMAKE_TOOLCHAIN_FILE=$PSPDEV/psp/share/pspdev.cmake) and build; the exact
# commands are in app/psp/README.md. The build produces build-psp/EBOOT.PBP.

cmake_minimum_required(VERSION 3.13)

project(rpg2k_psp C CXX ASM)

set(REPO_ROOT ${CMAKE_CURRENT_SOURCE_DIR}/../..)

# pspsdk static libraries are built without gp-relative small-data addressing;
# every object linked with them (LVGL, uni-algo, mruby and our own) must match,
# so force -G0 at directory scope before any of them are added.
add_compile_options(-G0)

# LVGL ships ARM Helium/NEON SIMD blend kernels as hand-written .S assembly and
# its CMake adds them to the lvgl target. The PSP is MIPS/Allegrex with neither
# SIMD, and psp-as chokes on the C typedefs these .S files pull in via stdint.h
# ("unrecognized opcode `typedef ...'"). LV_USE_DRAW_SW_ASM is NONE (see
# app/psp/lv_conf.h) so they are unused anyway -- delete them before LVGL is
# added (its CMake globs sources at configure time) so they are never assembled.
# Mirrors app/wio/exclude_lvgl_asm.py, which does the same for the PlatformIO
# build. Harmless to the desktop/wasm builds: those use separate build trees and
# do not compile these files on x86.
file(GLOB_RECURSE _lvgl_asm ${REPO_ROOT}/3rd/lvgl/src/*.S)
if(_lvgl_asm)
  file(REMOVE ${_lvgl_asm})
endif()

# Build the vendored LVGL with the PSP-tuned lv_conf.h in this directory (same
# submodule the desktop and Wio builds use). LV_BUILD_CONF_DIR points LVGL's
# build at our config.
#
# Binary dir is "3rd/lvgl", not "lvgl": the psp mruby cross-build below (via
# rake, a separate build system from this CMake project) links against
# mruby-rgss's own linker.library_paths, which -- matching the root
# CMakeLists.txt's layout, where "3rd/lvgl" is genuinely the path from the repo
# root -- expects to find liblvgl.a at "${PROJECT_BUILD_DIR}/3rd/lvgl/lib".
# Verified against a real (host-compiler) build of the vendored LVGL/uni-algo
# CMakeLists.txt: LVGL places its archive at "<binary_dir>/lib/liblvgl.a";
# uni-algo places its directly at "<binary_dir>/libuni-algo.a" (its own
# CMakeLists.txt sets no output subdirectory) -- both reflected below.
set(LV_BUILD_CONF_DIR
    ${CMAKE_CURRENT_SOURCE_DIR}
    CACHE PATH "lv_conf.h location" FORCE)
# LVGL's desktop CMake builds its examples and demos into the `lvgl` library
# itself (they are PUBLIC-linked), and their sources call widget constructors
# that app/psp/lv_conf.h disables -- so building them would fail to compile, and
# even when they did compile, every byte of them is RAM-resident on the PSP (the
# whole EBOOT is loaded into memory at launch). The RGSS runtime and the idle
# status screen need none of them, so keep both out of the EBOOT.
set(CONFIG_LV_BUILD_EXAMPLES OFF)
set(CONFIG_LV_BUILD_DEMOS OFF)
add_subdirectory(${REPO_ROOT}/3rd/lvgl 3rd/lvgl EXCLUDE_FROM_ALL)

# mruby-rgss and mruby-lcf both link uni-algo (Unicode normalisation / CP932
# conversion). See the LVGL comment above for why the binary dir must be
# "3rd/uni-algo".
add_subdirectory(${REPO_ROOT}/3rd/uni-algo 3rd/uni-algo EXCLUDE_FROM_ALL)

# Build libmruby.a for the psp target via mruby's own rake-based build system
# (build_config.rb's `psp` MRuby::CrossBuild), the same way the root
# CMakeLists.txt does for the desktop/wasm builds -- factored into
# cmake/build-mruby.cmake since both drive the same rake invocation with only
# the target name, gem list and a few extra rake options differing.
#
# Unlike the root build, no native `mrbc`-producing host build needs its own
# CC/CXX override here: build_config.rb's psp block hardcodes psp-gcc/psp-g++
# directly (conf.cc.command = 'psp-gcc', ...), and the host build alongside it
# (which still produces mrbc) uses the ambient CC/CXX -- ordinary host
# compilers, since this CMake project's own C/CXX compiler *is* the psp
# cross-compiler (set via the pspdev toolchain file), not a host one.
include(${REPO_ROOT}/cmake/build-mruby.cmake)
rpg2k_add_mruby(
  TARGET_NAME
  psp
  REPO_ROOT
  ${REPO_ROOT}
  PROJECT_BUILD_DIR
  ${CMAKE_CURRENT_BINARY_DIR}
  # Mirrors the root CMakeLists.txt's gem list, trimmed to what
  # build_config.rb's psp cross-build actually pulls in (rpg_maker_gems with
  # include_mvjs: false -- no mruby-mvjs/quickjs on this target).
  GEMS
  mruby-rgss
  mruby-lcf
  mruby-rpg2k
  mruby-rpgxp
  mruby-rpgvx
  MRB_OPTS
  MRUBY_TARGET=psp)

# The bring-up HAL (mruby-rgss/src/psp.cxx) now comes from libmruby.a -- the psp
# cross-build compiles it as part of the mruby-rgss gem, self-guarded on
# PSP_BUILD the same way it always was. Compiling it here directly too, as the
# earlier HAL-only bring-up did, would double-define every symbol in it
# (psp_display_create, psp_input_scan, ...) once both this executable and
# libmruby.a define them.
add_executable(rpg2k_psp main.cxx)

target_compile_definitions(rpg2k_psp PRIVATE PSP_BUILD LV_CONF_INCLUDE_SIMPLE)
target_include_directories(rpg2k_psp PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}
                                             ${REPO_ROOT}/include)

# libpspkernel.a bundles its own "ForKernel" NID-stub implementations of a
# handful of libc functions (seen so far: strtol, strtoul) alongside the real
# ones this user-mode (THREAD_ATTR_USER) EBOOT actually wants from newlib's
# libc.a -- both get pulled into the link (each also resolves other symbols
# genuinely needed from the same object) and collide as a hard "multiple
# definition" error. --allow-multiple-definition keeps the first definition ld
# encounters and discards the rest; libc.a is linked implicitly ahead of the
# explicit libraries below, so that first definition is newlib's real one.
target_link_options(rpg2k_psp PRIVATE -Wl,--allow-multiple-definition)

target_link_libraries(
  rpg2k_psp
  mruby
  lvgl
  uni-algo::uni-algo
  pspdisplay
  pspge
  pspctrl
  pspdebug
  pspaudio
  m
  stdc++
  pspkernel
  pspuser)

# Wrap the ELF into an EBOOT.PBP the PSP can run. create_pbp_file comes from the
# pspdev CMake toolchain; fail loudly if the project was configured without it.
if(NOT COMMAND create_pbp_file)
  message(
    FATAL_ERROR
      "create_pbp_file not found -- configure with the pspdev toolchain: "
      "-DCMAKE_TOOLCHAIN_FILE=$PSPDEV/psp/share/pspdev.cmake")
endif()

create_pbp_file(
  TARGET
  rpg2k_psp
  ICON_PATH
  NULL
  BACKGROUND_PATH
  NULL
  PREVIEW_PATH
  NULL
  TITLE
  "rpg2k PSP bring-up")
