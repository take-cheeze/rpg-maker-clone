# Standalone pspdev CMake project for the PSP EBOOT -- HAL bring-up.
#
# This is additive to and independent of the desktop CMake build at the repo
# root: it is a separate project rooted here, mirroring how platformio.ini keeps
# the Wio firmware separate. Building it does not touch the desktop/wasm builds,
# and vice versa. See app/psp/README.md and docs/adr/0010-psp-port.md.
#
# It requires the pspdev toolchain (https://github.com/pspdev/pspdev), which
# provides psp-gcc and the CMake toolchain file + create_pbp_file macro:
#
#   cmake -S app/psp -B build-psp \
#     -DCMAKE_TOOLCHAIN_FILE=$PSPDEV/psp/share/pspdev.cmake
#   cmake --build build-psp        # -> build-psp/EBOOT.PBP

cmake_minimum_required(VERSION 3.13)

project(rpg2k_psp C CXX ASM)

set(REPO_ROOT ${CMAKE_CURRENT_SOURCE_DIR}/../..)

# pspsdk static libraries are built without gp-relative small-data addressing;
# every object linked with them (LVGL and our own) must match, so force -G0 at
# directory scope before LVGL is added.
add_compile_options(-G0)

# Build the vendored LVGL with the PSP-tuned lv_conf.h in this directory (same
# submodule the desktop and Wio builds use). LV_BUILD_CONF_DIR points LVGL's
# build at our config.
set(LV_BUILD_CONF_DIR
    ${CMAKE_CURRENT_SOURCE_DIR}
    CACHE PATH "lv_conf.h location" FORCE)
add_subdirectory(${REPO_ROOT}/3rd/lvgl lvgl EXCLUDE_FROM_ALL)

# The bring-up EBOOT: the platform HAL (compiled straight from the mruby-rgss
# gem, self-guarded on PSP_BUILD) plus the entry-point sketch. libmruby and the
# input bridge are layered on in a later slice.
add_executable(
  rpg2k_psp
  main.cxx
  ${REPO_ROOT}/mruby-rgss/src/psp.cxx)

target_compile_definitions(rpg2k_psp PRIVATE PSP_BUILD LV_CONF_INCLUDE_SIMPLE)
target_include_directories(rpg2k_psp PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}
                                             ${REPO_ROOT}/include)

target_link_libraries(
  rpg2k_psp
  lvgl
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
  TARGET rpg2k_psp
  ICON_PATH NULL
  BACKGROUND_PATH NULL
  PREVIEW_PATH NULL
  TITLE "rpg2k PSP bring-up")
