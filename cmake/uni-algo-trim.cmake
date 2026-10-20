# Turn off the uni-algo modules this project never calls, so their Unicode
# tables are never compiled into any target's read-only data.
#
# This repo uses exactly three things from uni-algo: UTF conversion
# (`una::utf32to8` / `una::utf8to32u` in mruby-lcf/src/lcf.cxx), the UTF-8
# decoding view (`s | una::views::utf8` in mruby-rgss/src/lib.cxx) and NFD
# normalisation (`una::norm::to_nfd_utf8`, likewise). Conversion and the view
# carry no tables at all; NFD needs only the decomposition/combining-class data.
# Everything else uni-algo ships -- case mapping, collation, code-point
# properties, script lookup, grapheme/word segmentation and the compatibility
# (NFKC/NFKD) normalisation forms -- is dead weight here, and each one is a
# large static table rather than a little code.
#
# Measured on the PSP EBOOT (psp-gcc, `nm --size-sort`): the `una::detail::*`
# tables account for 663 KB of a 2.24 MB `.rodata`, and the modules disabled
# below are most of that. On the PSP that is live RAM, not just image size --
# the loader maps every PT_LOAD segment of the EBOOT into the console's ~24 MB
# at launch -- which makes it ADR 0047 (P6) work; it is also the `uni-algo` half
# of ADR 0007's P2 lever for the Wio Terminal, whose 512 KB of internal flash
# cannot hold the full table set at all. Desktop and wasm get the same reduction
# for free, since the modules are equally unused there.
#
# Every one of these is gated in uni-algo's own headers (see its
# `include/uni_algo/config.h`, which documents the size each one saves), so
# disabling a module the project does call would be a compile error at the call
# site -- `norm.h` `#error`s outright on `UNI_ALGO_DISABLE_NORM` -- not a silent
# behaviour change.
#
# The defines have to reach two different build systems, because the library and
# its callers are compiled separately: this list applies to the CMake `uni-algo`
# target (PUBLIC, so it covers both `src/data.cpp` -- where the tables live --
# and every CMake target that links it), while build_config.rb applies the same
# list to the mruby cross-builds' own C++ flags so the gem sources that include
# uni-algo's headers agree with the library they link. Keep the two lists in
# sync.
set(RPG2K_UNI_ALGO_TRIM_DEFINES
    UNI_ALGO_DISABLE_CASE # case mapping + collation, ~300 KB
    UNI_ALGO_DISABLE_PROP # code-point properties, ~35 KB
    UNI_ALGO_DISABLE_SCRIPT # script lookup, ~70 KB
    UNI_ALGO_DISABLE_SEGMENT_GRAPHEME # grapheme breaking, ~25 KB
    UNI_ALGO_DISABLE_SEGMENT_WORD) # word breaking, ~35 KB

# The compatibility normalisation forms (~100 KB of decomposition tables) are
# switched off for the data translation unit *only*, deliberately, rather than
# joining the PUBLIC list above -- uni-algo 1.2.0 cannot compile its own
# `impl_norm.h` with `UNI_ALGO_DISABLE_NFKC_NFKD` defined. The define guards
# both the NFKD tables and the plain `constexpr norm_bound_nfkd = 0x00A0` beside
# them (`impl_norm.h:204`), but `stages_qc_yes_ns` (`:254`) reads that constant
# unconditionally -- it needs the NFKD lower bound to count non-starters for
# Stream-Safe Text Process even on the *NFD* path, as its own comment says. So
# any caller that includes `norm.h` with the define set fails to compile, which
# is an upstream over-gating bug, not something this project is doing wrong.
#
# Scoping it to `src/data.cpp` sidesteps that cleanly, because data.cpp never
# includes `impl_norm.h` at all: it includes `internal/data_inl.h`, which pulls
# in only `impl/impl_data.h` (the tables) and the locale glue. The tables are
# plain `extern const` arrays, so dropping their definitions while callers still
# see the declarations costs nothing as long as nothing calls a compatibility
# normalisation function -- and if something ever does, it is an
# undefined-reference link error naming the missing table, not a silent
# behaviour change.
set(RPG2K_UNI_ALGO_TRIM_DEFINES_DATA_ONLY UNI_ALGO_DISABLE_NFKC_NFKD)

# Apply the lists to the vendored uni-algo target. Call this straight after the
# add_subdirectory that creates it, before anything links it.
function(rpg2k_trim_uni_algo)
  target_compile_definitions(uni-algo PUBLIC ${RPG2K_UNI_ALGO_TRIM_DEFINES})
  target_compile_definitions(uni-algo
                             PRIVATE ${RPG2K_UNI_ALGO_TRIM_DEFINES_DATA_ONLY})
endfunction()
