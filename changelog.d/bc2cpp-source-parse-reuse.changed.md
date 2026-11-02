- **bc2cpp:** share unchanged parsed syntax across source readers and cache source-only gem-owner
  and lint facts across processes. Keys include source contents and parser versions; lint baseline
  and source-set edits remain visible, while world-specific proofs and generated methods are recomputed.
