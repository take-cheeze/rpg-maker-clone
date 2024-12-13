cmake_minimum_required(VERSION 3.10)

if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE RelWithDebInfo)
endif()

project(rpg_maker_clone CXX)

find_package(Ruby REQUIRED)
find_package(SDL2 REQUIRED)

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
set(LIBMRUBY_A "${MRUBY_BUILD_DIR}/host/lib/libmruby.a")
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
add_custom_command(
  OUTPUT "${LIBMRUBY_A}"
  COMMAND
    mkdir -p ${MRUBY_BUILD_DIR}/repos/host && rm -f
    ${MRUBY_BUILD_DIR}/repos/host/mgem-list && ln -sf
    ${CMAKE_CURRENT_SOURCE_DIR}/3rd/mgem-list
    ${MRUBY_BUILD_DIR}/repos/host/mgem-list && ${MRB_OPTS} rake -v
  WORKING_DIRECTORY "${MRUBY_PREFIX}"
  DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/build_config.rb" ${MRB_FILES})
add_custom_target(mruby_build DEPENDS "${LIBMRUBY_A}")
add_dependencies(mruby mruby_build)

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

install(TARGETS ${PROJECT_NAME} RUNTIME)

enable_testing()

add_test(
  NAME mruby_test
  COMMAND env ${MRB_OPTS} rake test
  WORKING_DIRECTORY "${MRUBY_PREFIX}")

add_test(
  NAME exe_open
  COMMAND ${CMAKE_CURRENT_BINARY_DIR}/rpg_maker_clone --timeout_ms=100
          --game_dir ./data/Nepheshel206beta/Nepheshel206Rbeta
  WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR})
