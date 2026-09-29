- **bc2cpp** backward register scans (`IrepScans#walk_writers`,
  `Irep#last_writer_index`) jump between instructions that lead with the
  followed register through a per-irep index instead of testing every
  instruction. Scans with a `barrier:` still visit each instruction. Output is
  byte-identical.
