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
#   scripts/gen_emscripten_probe_cache.rb /tmp/wasm-probe/CMakeCache.txt \
#     > cmake/emscripten-probe-cache.cmake
# ~~~

set(EMSCRIPTEN_PROBE_CACHE_VERSION "5.0.6")

if(NOT EMSCRIPTEN_VERSION VERSION_EQUAL "${EMSCRIPTEN_PROBE_CACHE_VERSION}")
  message(
    STATUS
      "Emscripten ${EMSCRIPTEN_VERSION} does not match the pre-seeded probe "
      "cache (${EMSCRIPTEN_PROBE_CACHE_VERSION}); probing the toolchain "
      "instead. Regenerate cmake/emscripten-probe-cache.cmake to speed this "
      "configure back up -- see the header of that file.")
  file(WRITE "${CMAKE_BINARY_DIR}/emscripten-probe-cache.status"
       "stale ${EMSCRIPTEN_VERSION} != ${EMSCRIPTEN_PROBE_CACHE_VERSION}\n")
  return()
endif()

file(WRITE "${CMAKE_BINARY_DIR}/emscripten-probe-cache.status"
     "applied ${EMSCRIPTEN_PROBE_CACHE_VERSION}\n")

set("COMPILER_HAS_DEPRECATED"
    "1"
    CACHE INTERNAL "")
set("COMPILER_HAS_DEPRECATED_ATTR"
    "1"
    CACHE INTERNAL "")
set("COMPILER_HAS_HIDDEN_INLINE_VISIBILITY"
    "1"
    CACHE INTERNAL "")
set("COMPILER_HAS_HIDDEN_VISIBILITY"
    "1"
    CACHE INTERNAL "")
set("COMPILER_SUPPORTS_Wall"
    "1"
    CACHE INTERNAL "")
set("COMPILER_SUPPORTS_Wextra"
    "1"
    CACHE INTERNAL "")
set("COMPILER_SUPPORTS_Wformat=2"
    "1"
    CACHE INTERNAL "")
set("COMPILER_SUPPORTS_Wnoarraybounds"
    "1"
    CACHE INTERNAL "")
set("COMPILER_SUPPORTS_Wnoimplicitfallthrough"
    "1"
    CACHE INTERNAL "")
set("COMPILER_SUPPORTS_Wnomissingfieldinitializers"
    "1"
    CACHE INTERNAL "")
set("COMPILER_SUPPORTS_Wnosigncompare"
    "1"
    CACHE INTERNAL "")
set("COMPILER_SUPPORTS_Wnostringoptruncation"
    ""
    CACHE INTERNAL "")
set("COMPILER_SUPPORTS_Wnounusedbutsetvariable"
    "1"
    CACHE INTERNAL "")
set("COMPILER_SUPPORTS_Wnounusedparameter"
    "1"
    CACHE INTERNAL "")
set("COMPILER_SUPPORTS_Wnounusedresult"
    "1"
    CACHE INTERNAL "")
set("COMPILER_SUPPORTS_funsignedchar"
    "1"
    CACHE INTERNAL "")
set("HAVE_DBGHELP"
    ""
    CACHE INTERNAL "")
set("HAVE_DLADDR"
    "1"
    CACHE INTERNAL "")
set("HAVE_DLFCN_H"
    "1"
    CACHE INTERNAL "")
set("HAVE_ELF_H"
    "1"
    CACHE INTERNAL "")
set("HAVE_EXECINFO_BACKTRACE"
    ""
    CACHE INTERNAL "")
set("HAVE_EXECINFO_BACKTRACE_SYMBOLS"
    ""
    CACHE INTERNAL "")
set("HAVE_FCNTL"
    "1"
    CACHE INTERNAL "")
set("HAVE_FNMATCH_H"
    "1"
    CACHE INTERNAL "")
set("HAVE_GETPROGNAME"
    ""
    CACHE INTERNAL "")
set("HAVE_GLOB_H"
    "1"
    CACHE INTERNAL "")
set("HAVE_GMTIME_R"
    "1"
    CACHE INTERNAL "")
set("HAVE_HAVE_MODE_T"
    "TRUE"
    CACHE INTERNAL "")
set("HAVE_HAVE_SSIZE_T"
    "TRUE"
    CACHE INTERNAL "")
set("HAVE_INTTYPES_H"
    "1"
    CACHE INTERNAL "")
set("HAVE_LINK_H"
    "1"
    CACHE INTERNAL "")
set("HAVE_LOCALTIME_R"
    "1"
    CACHE INTERNAL "")
set("HAVE_MODE_T"
    "4"
    CACHE INTERNAL "")
set("HAVE_NANOSLEEP"
    "1"
    CACHE INTERNAL "")
set("HAVE_PC_FROM_UCONTEXT_uc_mcontext_gregs_REG_EIP"
    "1"
    CACHE INTERNAL "")
set("HAVE_PC_FROM_UCONTEXT_uc_mcontext_gregs_REG_PC"
    ""
    CACHE INTERNAL "")
set("HAVE_POSIX_FADVISE"
    "1"
    CACHE INTERNAL "")
set("HAVE_PREAD"
    "1"
    CACHE INTERNAL "")
set("HAVE_PROGRAM_INVOCATION_SHORT_NAME"
    "1"
    CACHE INTERNAL "")
set("HAVE_PWD_H"
    "1"
    CACHE INTERNAL "")
set("HAVE_PWRITE"
    "1"
    CACHE INTERNAL "")
set("HAVE_SCHED_YIELD"
    "1"
    CACHE INTERNAL "")
set("HAVE_SIGACTION"
    "1"
    CACHE INTERNAL "")
set("HAVE_SIGALTSTACK"
    "1"
    CACHE INTERNAL "")
set("HAVE_SSIZE_T"
    "4"
    CACHE INTERNAL "")
set("HAVE_STDDEF_H"
    "1"
    CACHE INTERNAL "")
set("HAVE_STDINT_H"
    "1"
    CACHE INTERNAL "")
set("HAVE_STRTOLL"
    "1"
    CACHE INTERNAL "")
set("HAVE_SYSCALL_H"
    "1"
    CACHE INTERNAL "")
set("HAVE_SYSLOG_H"
    "1"
    CACHE INTERNAL "")
set("HAVE_SYS_EXEC_ELF_H"
    ""
    CACHE INTERNAL "")
set("HAVE_SYS_STAT_H"
    "1"
    CACHE INTERNAL "")
set("HAVE_SYS_SYSCALL_H"
    "1"
    CACHE INTERNAL "")
set("HAVE_SYS_TIME_H"
    "1"
    CACHE INTERNAL "")
set("HAVE_SYS_TYPES_H"
    "1"
    CACHE INTERNAL "")
set("HAVE_SYS_UTSNAME_H"
    "1"
    CACHE INTERNAL "")
set("HAVE_SYS_WAIT_H"
    "1"
    CACHE INTERNAL "")
set("HAVE_UCONTEXT_H"
    "1"
    CACHE INTERNAL "")
set("HAVE_UNISTD_H"
    "1"
    CACHE INTERNAL "")
set("HAVE__CHSIZE_S"
    ""
    CACHE INTERNAL "")
set("HAVE___ARGV"
    ""
    CACHE INTERNAL "")
set("HAVE___CXA_DEMANGLE"
    "1"
    CACHE INTERNAL "")
set("HAVE___PROGNAME"
    "1"
    CACHE INTERNAL "")
set("HAVE_uint32_t"
    "TRUE"
    CACHE INTERNAL "")
set("PC_FROM_UCONTEXT"
    "uc_mcontext.gregs[REG_EIP]"
    CACHE STRING "")
