#!/usr/bin/env ruby
# frozen_string_literal: true

# Regenerate cmake/emscripten-probe-cache.cmake from a real Emscripten
# configure, so the pre-seeded probe answers are always transcribed from a
# toolchain that actually produced them rather than written by hand.
#
#   emcmake cmake -S . -B /tmp/wasm-probe -GNinja
#   scripts/gen_emscripten_probe_cache.rb /tmp/wasm-probe/CMakeCache.txt \
#     > cmake/emscripten-probe-cache.cmake
#
# The Emscripten version is read out of the build tree's own compiler
# configuration, so the guard in the generated file always matches the toolchain
# the values came from.

require 'pathname'

cache_path = ARGV[0]
abort "usage: #{$PROGRAM_NAME} <path/to/CMakeCache.txt>" if cache_path.nil?
abort "no such file: #{cache_path}" unless File.file?(cache_path)

build_dir = Pathname.new(cache_path).dirname

# The compiler path records the Emscripten release the probes ran against; the
# toolchain file exposes the same number as EMSCRIPTEN_VERSION at configure
# time, which is what the generated guard compares against.
compiler_cfg = Dir.glob(build_dir.join('CMakeFiles', '*', 'CMakeCXXCompiler.cmake')).first
abort "no CMakeCXXCompiler.cmake under #{build_dir}" if compiler_cfg.nil?

compiler = File.read(compiler_cfg)[/set\(CMAKE_CXX_COMPILER "([^"]+)"\)/, 1].to_s
version = compiler[%r{emscripten-(\d+(?:\.\d+)+)}, 1]
abort "could not read the Emscripten version out of #{compiler.inspect}" if version.nil?

# The cache variables the check_* macros write. Every one of these is a result
# CMake will skip re-probing when it is already set.
KEEP = /\A(HAVE_[A-Za-z0-9_]*|COMPILER_SUPPORTS_[A-Za-z0-9_=]*|COMPILER_HAS_[A-Za-z0-9_]*|PC_FROM_UCONTEXT)\z/
entries = File.readlines(cache_path).filter_map do |line|
  name, rest = line.chomp.split(':', 2)
  next if rest.nil?

  type, value = rest.split('=', 2)
  next if value.nil?
  # `-ADVANCED` companions only control cmake-gui visibility, not any probe.
  next if name.end_with?('-ADVANCED')
  next unless KEEP.match?(name)

  [name, type, value]
end.sort

abort 'no probe results found - was this configured with emcmake?' if entries.empty?

puts <<~HEADER
  # Pre-seeded results of the configure-time compiler probes, for Emscripten.
  #
  # Configuring the wasm build costs ~110s, and ~104s of that is 62 nested
  # try_compile projects: every check_include_file_cxx / check_cxx_symbol_exists /
  # check_c_compiler_flag in ng-log, gflags, quickjs and lvgl runs a full emcc
  # invocation (python driver, clang, wasm-ld) rather than the sub-100ms cc the
  # native build pays, at ~1.7s each. The answers are fixed properties of the
  # Emscripten sysroot, so probing for them on every build is pure repetition.
  #
  # Every check_* macro is a no-op when its result variable is already in the
  # cache, so seeding them here skips the try_compile projects outright and the
  # subprojects see exactly the values they would have computed.
  #
  # THESE VALUES ARE TOOLCHAIN-SPECIFIC. They are only applied when the Emscripten
  # version matches the one they were generated with (see the guard below); any
  # other version falls through to probing normally, so a toolchain bump costs
  # configure time but can never silently apply a wrong answer.
  #
  # Whichever branch is taken is recorded in emscripten-probe-cache.status in the
  # build tree, so a caller can tell "the seed applied" from "the seed was stale
  # and the toolchain got probed" without parsing the configure log. CI asserts on
  # it; see scripts/check_emscripten_probe_cache.bash, which additionally
  # re-probes and diffs to catch values that went stale *without* the version
  # changing (a sysroot rebuilt under the same release, say).
  #
  # GENERATED FILE - do not edit by hand. To regenerate after an Emscripten bump
  # or a 3rd/ submodule update:
  #
  # ~~~
  #   emcmake cmake -S . -B /tmp/wasm-probe -GNinja
  #   scripts/gen_emscripten_probe_cache.rb /tmp/wasm-probe/CMakeCache.txt \\
  #     > cmake/emscripten-probe-cache.cmake
  # ~~~

  set(EMSCRIPTEN_PROBE_CACHE_VERSION "#{version}")

  if(NOT EMSCRIPTEN_VERSION VERSION_EQUAL "${EMSCRIPTEN_PROBE_CACHE_VERSION}")
    message(
      STATUS
        "Emscripten ${EMSCRIPTEN_VERSION} does not match the pre-seeded probe "
        "cache (${EMSCRIPTEN_PROBE_CACHE_VERSION}); probing the toolchain "
        "instead. Regenerate cmake/emscripten-probe-cache.cmake to speed this "
        "configure back up -- see the header of that file.")
    file(WRITE "${CMAKE_BINARY_DIR}/emscripten-probe-cache.status"
         "stale ${EMSCRIPTEN_VERSION} != ${EMSCRIPTEN_PROBE_CACHE_VERSION}\\n")
    return()
  endif()

  file(WRITE "${CMAKE_BINARY_DIR}/emscripten-probe-cache.status"
       "applied ${EMSCRIPTEN_PROBE_CACHE_VERSION}\\n")

HEADER

puts entries.map { |name, type, value|
  %(set("#{name}"\n    "#{value}"\n    CACHE #{type} ""))
}.join("\n")
