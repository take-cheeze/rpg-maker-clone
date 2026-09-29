# 251. bc2cpp builds every Irep from the RITE binary; the C dump and text loaders are gone

Date: 2026-09-29

## Status

Accepted. Completes the follow-up of ADR 0249.

## Context

ADR 0249 moved the instruction stream to the RITE binary, but irep metadata
(label, `nlocals`/`nregs`, pool, symbols, `reps`, local names) still came from
regexes over `mrbc -B -S`'s C source, zipped against the binary by DFS order.
The regex scan was lossy: it only recognised `MRB_SYM`/`MRB_IVSYM`, so symbols
printed as `MRB_SYM_Q/B/E`, `MRB_OPSYM`, `MRB_CVSYM`, or interned at load time
(`0` plus a `mrb_intern_lit` line, e.g. `**`) were dropped from `syms`/`lv`.
`BC2CPP_TEXT_LOADER=1` also kept a second, text-based instruction loader.

## Decision

`load_ireps` (tools/bc2cpp/irep.rb) builds the whole `Irep` tree from the
binary: `RiteBinary` now records each irep's child count, so the tree is rebuilt
from the pre-order list. `syms` and `lv` are the exact names (nil for a null
symbol), including `**`.

Labels are part of generated C++ names, so they reproduce the numbering of
`mrbc -S` bug for bug (`assign_irep_labels`): root 0; an irep with k children
reserves k numbers per child, starting from 1, before descending. The
`label => Irep` hash is filled children-first, the order the C dump listed
ireps, because passes iterate it. Pool entries keep their shape (String for
strings; `{type:, raw:}` with the C initializer text otherwise, int64 values
that fit int32 narrowed as `mrbc -S` did).

Removed: `parse_c_dump`, `parse_disasm_blocks`, `merge!`, `run_mrbc_text`,
`BC2CPP_TEXT_LOADER`. `run_mrbc` only runs `mrbc -g`; `compile_ireps` is the
entry point for tools and checks.

`scripts/bc2cpp_binary_loader_check.rb` keeps the independent evidence: it
parses `mrbc -v` (headers, file, catch handlers, every instruction) and the
`-B -S` C source (labels, reps, nlocals/nregs, pool, exact symbol and local
names, including the operator table) inside the script only, and compares both
with the binary loader.

## Consequences

- Generated output for the whole closed world is byte-identical; the only Irep
  difference is that `lv` now contains `**` where it used to hold nil (not read
  by any pass at those positions).
- No pass or tool depends on `mrbc` text or C output.
- Symbols with any spelling decode exactly.
