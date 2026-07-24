cmake_minimum_required(VERSION 3.10)

if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE RelWithDebInfo)
endif()

project(rpg_maker_clone CXX)

if(EMSCRIPTEN)
  # Emscripten ships SDL2 as a "port": -sUSE_SDL=2 provides both the headers
  # (needed while compiling lvgl's SDL driver) and the library at link time.
  add_compile_options("-sUSE_SDL=2")
  add_link_options("-sUSE_SDL=2")
  # mruby is built with MRB_USE_CXX_EXCEPTION and throws real C++ exceptions for
  # its internal control flow, so exception support must be enabled across the
  # whole binary; otherwise the first throw aborts in the catch machinery.
  add_compile_options("-fexceptions")
  add_link_options("-fexceptions")
  # Provide a stand-in for the SDL2::SDL2 target the executable links against.
  add_library(SDL2::SDL2 INTERFACE IMPORTED)
else()
  find_package(SDL2 REQUIRED)
endif()

include_directories(${CMAKE_CURRENT_SOURCE_DIR}/include)
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
target_include_directories(mruby INTERFACE "${MRUBY_PREFIX}/include")
# Collect the source of each local mrbgem so libmruby.a rebuilds when any of it
# changes. GLOB_RECURSE also picks up files in nested subdirectories, and
# CONFIGURE_DEPENDS makes CMake re-run the glob at build time: adding or
# removing a source file triggers a reconfigure (and thus a libmruby rebuild) on
# the next `make`, with no manual `cmake` re-run. Header changes under src/ are
# caught too so an edit to a private header still forces the archive to be
# rebuilt.
foreach(g mruby-rgss mruby-lcf mruby-rpg2k mruby-rpgxp)
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

add_executable(${PROJECT_NAME} src/main.cxx src/sdl_input.cxx)
target_link_libraries(
  ${PROJECT_NAME}
  mruby
  lvgl
  ng-log::ng-log
  SDL2::SDL2
  gflags
  uni-algo::uni-algo)
target_include_directories(${PROJECT_NAME}
                           PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/3rd/inicpp)

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
    # Debug info + runtime checks for the browser: keep DWARF in the wasm,
    # verbose assertions, heap-access validation, and stack-overflow detection
    # to catch the mruby init corruption early instead of as an opaque trap.
    "-g3"
    # Emit index.wasm.map so Chrome symbolicates wasm frames to file:line in
    # console stack traces (DWARF alone only feeds the debugger UI, not the
    # printed trace text). The file:line text resolves from the map with no base
    # URL needed; serving the sources is only required to view the code. C++
    # exception throw sites get real stack traces too.
    "-gsource-map"
    "-sEXCEPTION_STACK_TRACES=1"
    "-sASSERTIONS=2"
    "-sSAFE_HEAP=1"
    "-sSTACK_OVERFLOW_CHECK=2"
    # Use our own page (canvas + on-screen keypad) instead of Emscripten's
    # default shell. rgss_wasm_key is exported via EMSCRIPTEN_KEEPALIVE, so it
    # needs no EXPORTED_FUNCTIONS entry.
    "--shell-file=${CMAKE_CURRENT_SOURCE_DIR}/src/shell.html"
    "${ONIGMO_A}")
  # Relink the page when the shell template changes (CMake does not track the
  # --shell-file input on its own).
  set_property(
    TARGET ${PROJECT_NAME}
    APPEND
    PROPERTY LINK_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/src/shell.html")
  # Optionally bake a game directory into the virtual filesystem at /game so the
  # page runs a real game. Pass -DWASM_GAME_DIR=/abs/path/to/game at configure
  # time; then the page auto-loads it via --game_dir=/game.
  if(WASM_GAME_DIR)
    file(REAL_PATH ${WASM_GAME_DIR} WASM_GAME_DIR)
    target_link_options(${PROJECT_NAME} PRIVATE
                        "--preload-file=${WASM_GAME_DIR}@/game")
  endif()
endif()

install(TARGETS ${PROJECT_NAME} RUNTIME)

enable_testing()

if(NOT EMSCRIPTEN)
  add_test(
    NAME mruby_test
    COMMAND env ${MRB_OPTS} rake test
    WORKING_DIRECTORY "${MRUBY_PREFIX}")

  add_test(
    NAME exe_open
    COMMAND ${CMAKE_CURRENT_BINARY_DIR}/rpg_maker_clone --timeout_ms=100
            --game_dir ./data/Nepheshel206beta/Nepheshel206Rbeta
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR})
endif()
