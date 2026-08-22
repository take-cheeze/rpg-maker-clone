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

# Pin the optimisation level. CMake initialises CMAKE_BUILD_TYPE from the
# environment variable of the same name, and this repo's nix devshell exports
# CMAKE_BUILD_TYPE=RelWithDebInfo -- so a local build inside `nix develop` got
# -O2 -g -DNDEBUG while the `psp` CI job, which runs in a bare pspdev container
# with no such variable, got an empty build type and therefore no optimisation
# flags at all. Two different builds of the same commit, neither declared
# anywhere, and the difference is not cosmetic: at -O2 this EBOOT halts on
# LVGL's TLSF assert (`!block_is_free(block)` in lv_tlsf_realloc,
# 3rd/lvgl/src/stdlib/builtin/lv_tlsf.c:1215) during display setup, while the
# unoptimised build boots to completion. Confirmed by building in the *same*
# container both ways: only the flag changed, and only the -O2 build asserts.
#
# So this is deliberately the unoptimised build, plus -g: it is the only
# configuration proven to reach RPG2K_PSP_MRUBY_OPEN and a running
# RPG2K_PSP_BRINGUP heartbeat, and while the port is still in bring-up (ADR
# 0047's P1 is about measuring this target at all) accurate line info and absent
# inlining are worth more than code size. The cost is measured and affordable:
# unoptimised .text is ~260 KB larger, against a boot that reports 782 KB heap
# free, a 256 KB LVGL pool running at 1.4%, and a 256 KB main stack at 6.4%. -g
# adds no RAM cost -- debug sections are not in a PT_LOAD.
#
# Provisional. Once the -O2 failure is root-caused, MinSizeRel (-Os -DNDEBUG) is
# the better long-term answer for a target whose whole image is RAM-resident at
# launch. Override deliberately with -DRPG2K_PSP_BUILD_TYPE=<type>; setting
# CMAKE_BUILD_TYPE directly (or via the environment) is intentionally ignored,
# since that ambient behaviour is the bug this pin exists to prevent.
set(RPG2K_PSP_BUILD_TYPE
    "Debug"
    CACHE STRING "Optimisation level for the PSP EBOOT")
set(CMAKE_BUILD_TYPE
    "${RPG2K_PSP_BUILD_TYPE}"
    CACHE STRING "" FORCE)

set(REPO_ROOT ${CMAKE_CURRENT_SOURCE_DIR}/../..)

# create_pbp_file's POST_BUILD chain runs "$ENV{PSPDEV}/bin/psp-fixup-imports"
# over the freshly linked ELF (see $PSPDEV/psp/share/CreatePBP.cmake). That tool
# has to be the JAL-relocation-aware build scripts/build_psp_fixup_imports.bash
# produces, not pspdev's stock one: the stock tool assumes every call site
# referencing a given PSP module is already physically contiguous in the linked
# binary's import metadata, which main.cxx's own ordinary control flow does not
# satisfy, and when it isn't it silently assigns some imports to the wrong
# module and still exits 0.
#
# Nothing downstream notices. The EBOOT links, packs, and boots far enough to
# print RPG2K_PSP_BOOT, but SysMemUserForUser ends up overlapping
# ThreadManForUser's stub table, which strands sceKernelAllocPartitionMemory and
# sceKernelGetBlockHeadAddr unbound -- so _sbrk never gets a heap, the first
# real malloc() never returns, and user_main deadlocks before the frame loop
# starts. That is indistinguishable at a glance from the pspuser/pspkernel
# link-order bug the target_link_libraries comment below describes, which is
# exactly why this is worth catching here instead of in a headless emulator run.
#
# Checked up here rather than beside create_pbp_file at the bottom so a stock
# toolchain fails in seconds, not after configuring LVGL, uni-algo and mruby.
#
# Detected by a format string only the patched tool carries: it is built from
# pspdev's own pinned pspsdk source, so nothing else about the binary
# (timestamp, size, --help output) reliably separates the two.
set(FIXUP_IMPORTS "$ENV{PSPDEV}/bin/psp-fixup-imports")
if(NOT EXISTS "${FIXUP_IMPORTS}")
  message(
    FATAL_ERROR
      "psp-fixup-imports not found at \"${FIXUP_IMPORTS}\" -- PSPDEV must "
      "point at the pspdev installation this build links against.")
endif()
# Re-run configure (and so this check) whenever the tool itself is replaced;
# installing the patched build is not a source change, so nothing else here
# would notice it had happened.
set_property(
  DIRECTORY
  APPEND
  PROPERTY CMAKE_CONFIGURE_DEPENDS "${FIXUP_IMPORTS}")
# REPO_ROOT is spelled relative to this directory, so normalise it before it
# goes into a message a reader is meant to paste into a shell.
get_filename_component(REPO_ROOT_ABS "${REPO_ROOT}" ABSOLUTE)
file(
  STRINGS "${FIXUP_IMPORTS}" FIXUP_IMPORTS_PATCHED
  REGEX "Repointed .* jal instruction"
  LIMIT_COUNT 1)
if(NOT FIXUP_IMPORTS_PATCHED)
  message(
    FATAL_ERROR
      "\"${FIXUP_IMPORTS}\" is pspdev's stock psp-fixup-imports. Building "
      "against it produces an EBOOT whose PSP imports resolve to the wrong "
      "modules -- it will boot far enough to look fine and then hang. Install "
      "the patched build over it first:\n"
      "    bash ${REPO_ROOT_ABS}/scripts/build_psp_fixup_imports.bash\n"
      "then force a relink (rm ${CMAKE_CURRENT_BINARY_DIR}/rpg2k_psp), since "
      "replacing the tool does not by itself make anything rebuild. See "
      "patches/psp-fixup-imports-jal-relocation-aware.patch.")
endif()

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
#
# These must be set as CACHE variables: LVGL's os_desktop.cmake gates its
# examples/demos behind `option(CONFIG_LV_BUILD_EXAMPLES ...)`, and with CMP0077
# unset (the project does not raise cmake_minimum_required past 3.12) option()
# only honours cache variables -- a plain set() is silently ignored, which is
# exactly how the examples leaked back into the PSP build's link.
set(CONFIG_LV_BUILD_EXAMPLES
    OFF
    CACHE BOOL "" FORCE)
set(CONFIG_LV_BUILD_DEMOS
    OFF
    CACHE BOOL "" FORCE)
add_subdirectory(${REPO_ROOT}/3rd/lvgl 3rd/lvgl EXCLUDE_FROM_ALL)

# mruby-rgss and mruby-lcf both link uni-algo (Unicode normalisation / CP932
# conversion). See the LVGL comment above for why the binary dir must be
# "3rd/uni-algo".
add_subdirectory(${REPO_ROOT}/3rd/uni-algo 3rd/uni-algo EXCLUDE_FROM_ALL)
# Drop the Unicode tables for the uni-algo modules nothing here calls. On the
# PSP this is live RAM, not just image size: every PT_LOAD segment of the EBOOT
# is mapped into the console's ~24 MB at launch. See cmake/uni-algo-trim.cmake.
include(${REPO_ROOT}/cmake/uni-algo-trim.cmake)
rpg2k_trim_uni_algo()

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
# libmruby.a define them. psp_unwind_fde.cxx must stay listed here, ahead of
# every library: it overrides two libgcc symbols and only wins the link because
# objects named in add_executable() precede the libraries under
# -Wl,--allow-multiple-definition (set below). See the file's own preamble for
# what it works around.
add_executable(rpg2k_psp main.cxx psp_unwind_fde.cxx)

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

# pspkernel.a and pspuser.a both provide sceKernelCreateCallback,
# sceKernelSleepThreadCB, and sceKernelMaxFreeMemSize -- as their genuinely
# distinct "ForKernel" and "ForUser" NIDs, not a benign duplicate the way the
# libc collision above is. Listing pspkernel first (as this used to) meant ld
# kept ITS "ForKernel" stub for the three under --allow-multiple-definition's
# same first-definition-wins rule, so this user-mode EBOOT's imports named the
# kernel-mode NID for each. PPSSPP's loader has no HLE implementation registered
# under those modules for a plain homebrew EBOOT, so every call came back
# SCE_KERNEL_ERROR_LIBRARY_NOT_YET_LINKED -- silently, since none of the three's
# callers (setup_callbacks' callback_thread, and _sbrk's heap-size probe in
# libcglue) check the return value. That's what was actually behind the PSP boot
# hanging under PPSSPP-headless past RPG2K_PSP_BOOT: _sbrk() re-ran its
# heap-init probe on every call forever (heap_bottom never left NULL, since
# sceKernelMaxFreeMemSize's bogus return made sceKernelAllocPartitionMemory fail
# too), so the first real malloc() never returned. pspuser first makes its
# correct "ForUser" definitions win instead, the same fix the libc case already
# relies on -- pspkernel stays linked after it for whatever else in this list
# still needs it.
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
  pspuser
  pspkernel)

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
  ${CMAKE_CURRENT_SOURCE_DIR}/../../assets/psp/icon0.png
  BACKGROUND_PATH
  NULL
  PREVIEW_PATH
  NULL
  TITLE
  "rpg2k PSP bring-up")
