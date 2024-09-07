cmake_minimum_required(VERSION 3.10)

if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE RelWithDebInfo)
endif()

project(rpg_maker_clone CXX)

find_package(Ruby REQUIRED)
find_package(SDL2 REQUIRED)

include_directories(${CMAKE_CURRENT_SOURCE_DIR}/include)
add_subdirectory(3rd/lvgl)

set(WITH_GTEST OFF)
set(WITH_GFLAGS OFF CACHE BOOL "" FORCE)
set(BUILD_STATIC_LIBS ON CACHE BOOL "" FORCE)
set(old_build_testing ${BUILD_TESTING})
set(BUILD_TESTING OFF)
add_subdirectory(3rd/gflags)
add_subdirectory(3rd/glog)
set(BUILD_TESTING ${old_build_testing})

set(MRUBY_PREFIX "${CMAKE_CURRENT_SOURCE_DIR}/3rd/mruby")
add_library(mruby STATIC IMPORTED)
set(MRUBY_BUILD_DIR "${CMAKE_CURRENT_BINARY_DIR}/mruby")
set(LIBMRUBY_A "${MRUBY_BUILD_DIR}/host/lib/libmruby.a")
set_target_properties(
  mruby PROPERTIES
  IMPORTED_LOCATION "${LIBMRUBY_A}"
  )
list(APPEND ADDITIONAL_CLEAN_FILES "${MRUBY_BUILD_DIR}")
target_include_directories(mruby INTERFACE "${MRUBY_PREFIX}/include")
add_custom_command(
  OUTPUT "${LIBMRUBY_A}"
  COMMAND
    mkdir -p ${MRUBY_BUILD_DIR}/repos/host &&
    ln -sf ${CMAKE_CURRENT_SOURCE_DIR}/3rd/mgem-list ${MRUBY_BUILD_DIR}/repos/host/mgem-list &&
    MRUBY_CONFIG=${CMAKE_CURRENT_SOURCE_DIR}/build_config.rb
    MRUBY_BUILD_DIR=${MRUBY_BUILD_DIR}
    BUILD_DIR=${MRUBY_BUILD_DIR}
    rake -v
  WORKING_DIRECTORY "${MRUBY_PREFIX}"
  DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/build_config.rb"
  )
add_custom_target(mruby_build DEPENDS "${LIBMRUBY_A}")
add_dependencies(mruby mruby_build)

add_executable(${PROJECT_NAME} src/main.cc)
target_link_libraries(${PROJECT_NAME} mruby lvgl glog SDL2::SDL2 gflags)

enable_testing()

add_test(
  NAME mruby_test
  COMMAND env MRUBY_CONFIG=${CMAKE_CURRENT_SOURCE_DIR}/build_config.rb rake test
  WORKING_DIRECTORY "${MRUBY_PREFIX}")

add_test(
  NAME exe_open
  COMMAND ${CMAKE_CURRENT_BINARY_DIR}/rpg_maker_clone --timeout_ms=100)
