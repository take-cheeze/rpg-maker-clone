# 223. Store mruby's presym names as one blob

Date: 2026-09-24

## Status

Accepted

## Context

mruby resolves every symbol known at build time (a "presym") through two
generated tables in `build/<target>/include/mruby/presym/table.h`:

- `presym_name_table`: one `const char *` per presym;
- `presym_length_table`: one `uint16_t` per presym.

The wio `wio_rgss_boot` firmware still overflows its 507,904 B flash, and
ADR 0143's symbol breakdown lists these two tables among the largest
single objects: 20,952 B and 10,476 B there. On a 32-bit target that is
6 bytes of index per presym, on top of the names themselves.

`MRuby::Presym#scan` already sorts presyms by (length, name). So all the
names of one length are one contiguous run, and a name's position in its
run is its index minus the run's first index.

## Decision

`patches/mruby-presym-compact-table.patch` changes the table format:

- `presym_name_blob`: every name, NUL-terminated, in presym order.
- `presym_len_start[L]`: the index of the first presym of length `L`
  (`L` = 0 … `MRB_PRESYM_LEN_MAX + 1`).
- `presym_len_offset[L]`: the blob offset of that first presym.

A name's address is `offset[L] + (idx - start[L]) * (L + 1)`.

- **Name → symbol** (`presym_find`) binary-searches only the run of the
  name's own length, instead of the whole table.
- **Symbol → name** (`presym_sym2name`) finds the run holding the index by
  binary search over `presym_len_start`, which has about 30 entries.

Names stay NUL-terminated, so `mrb_sym_name` still returns a C string.

`#scan` now sorts by `bytesize` rather than `size`. The files are read in
binary mode, so both give the same order today, and byte length is what
the lookup compares.

The patch is applied to every build (`cmake/build-mruby.cmake`,
`scripts/maix_mruby_build.bash`, `scripts/wio_bc2cpp_measure.bash`).

## Consequences

Measured with a full `wio_rgss_boot` link (the baseline configuration of
`scripts/wio_bc2cpp_measure.bash`), on top of ADR 0224's patch:

- **Flash: −18,384 B.** The wio build has 4,714 presyms. Before the patch,
  `presym_name_table` was 18,856 B and `presym_length_table` 9,428 B.
- **Static RAM:** unchanged. The tables were already `.rodata`.

- The per-length tables are a few hundred bytes whatever the presym count.
- Symbol → name costs a binary search over the length table (about five
  comparisons) instead of one array read. It is not on the method-dispatch
  path.
- mruby's own test suite (`rake all test`, `test:run:bin`) passes with the
  patch: 0 failures, apart from the sandbox-only `UDPSocket` crash that also
  happens without it.
