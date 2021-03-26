cmake_minimum_required(VERSION 3.10)

project(rpg_maker_clone CXX)

find_package(Ruby REQUIRED)

set(MRUBY_PREFIX "${CMAKE_CURRENT_SOURCE_DIR}/third_party/mruby")
add_library(mruby STATIC IMPORTED)
set(LIBMRUBY_A "${MRUBY_PREFIX}/build/host/lib/libmruby.a")
set_target_properties(
  mruby PROPERTIES
  IMPORTED_LOCATION "${LIBMRUBY_A}"
  )
set(ADDITIONAL_CLEAN_FILES "${MRUBY_PREFIX}/build")
target_include_directories(mruby INTERFACE "${MRUBY_PREFIX}/include")
add_custom_command(
  OUTPUT "${LIBMRUBY_A}"
  COMMAND MRUBY_CONFIG=${CMAKE_CURRENT_SOURCE_DIR}/build_config.rb rake
  WORKING_DIRECTORY "${MRUBY_PREFIX}"
  DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/build_config.rb"
  )
add_custom_target(mruby_build DEPENDS "${LIBMRUBY_A}")
add_dependencies(mruby mruby_build)

add_executable(${PROJECT_NAME} src/main.cc)
target_link_libraries(${PROJECT_NAME} mruby)

enable_testing()

add_test(
  NAME mruby_test
  COMMAND env MRUBY_CONFIG=${CMAKE_CURRENT_SOURCE_DIR}/build_config.rb rake test
  WORKING_DIRECTORY "${MRUBY_PREFIX}")
