- `tools/bc2cpp/compiled_gems.rb`'s `closed_world_mrblib_srcs` now
  returns its file list sorted: `Dir[]` yields filesystem order (ext4
  vs APFS disagree), and bc2cpp's own capped fixed-point sweeps
  converge order-dependently -- the same files in a different ARGV
  order flip real devirtualization counts (measured: 2 extra
  CLASS_HINTs, 70 fewer POLY marks on one shuffled order). Canonical
  order at the single shared source makes the coverage report, every
  `*-compiled` gem build, and every ad-hoc bc2cpp invocation agree on
  every filesystem. No behavior change on any single filesystem
  (regenerated `docs/bc2cpp_coverage.txt` is byte-identical); the
  analyses' own order-sensitivity (loop-until-stable) is left as a
  separately-tracked real bug, not papered over by this.
