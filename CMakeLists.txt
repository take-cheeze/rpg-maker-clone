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
foreach(g mruby-rgss mruby-lcf mruby-rpg2k mruby-rpgxp)
  file(GLOB cxx ${CMAKE_CURRENT_SOURCE_DIR}/${g}/src/*.cxx)
  file(GLOB rb ${CMAKE_CURRENT_SOURCE_DIR}/${g}/mrblib/*.rb)
  list(APPEND MRB_FILES ${cxx} ${rb}
       ${CMAKE_CURRENT_SOURCE_DIR}/${g}/mrbgem.rake)
endforeach()
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
add_custom_command(
  OUTPUT "${LIBMRUBY_A}"
  COMMAND
    mkdir -p ${MRUBY_BUILD_DIR}/repos/host
    ${MRUBY_BUILD_DIR}/repos/${MRUBY_TARGET_NAME} && ln -sf
    ${CMAKE_CURRENT_SOURCE_DIR}/3rd/mgem-list
    ${MRUBY_BUILD_DIR}/repos/host/mgem-list && ln -sf
    ${CMAKE_CURRENT_SOURCE_DIR}/3rd/mgem-list
    ${MRUBY_BUILD_DIR}/repos/${MRUBY_TARGET_NAME}/mgem-list && ${MRB_OPTS} rake
    -v
  WORKING_DIRECTORY "${MRUBY_PREFIX}"
  DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/build_config.rb" ${MRB_FILES})
add_custom_target(mruby_build DEPENDS "${LIBMRUBY_A}")
add_dependencies(mruby mruby_build)

if(EMSCRIPTEN)
  # Re-archive onigmo's pristine per-file wasm objects (see ONIGMO_A above).
  add_custom_command(
    OUTPUT "${ONIGMO_A}"
    COMMAND
      sh -c
      "${CMAKE_AR} crs '${ONIGMO_A}' $(find '${ONIGMO_DIR}' -name '*.o' -not -path '*/.libs/*')"
    DEPENDS "${LIBMRUBY_A}"
    VERBATIM)
  add_custom_target(onigmo_clean DEPENDS "${ONIGMO_A}")
endif()

add_executable(${PROJECT_NAME} src/main.cxx)
target_link_libraries(
  ${PROJECT_NAME}
  mruby
  lvgl
  glog
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
  target_link_options(${PROJECT_NAME} PRIVATE "-sALLOW_MEMORY_GROWTH=1"
                      "-sEXIT_RUNTIME=0" "-sFORCE_FILESYSTEM=1" "${ONIGMO_A}")
  # Optionally bake a game directory into the virtual filesystem at /game so the
  # page runs a real game. Pass -DWASM_GAME_DIR=/abs/path/to/game at configure
  # time; then the page auto-loads it via --game_dir=/game.
  if(WASM_GAME_DIR)
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
