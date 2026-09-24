- mruby's build-time symbol names are now stored as one blob with a small
  per-length index instead of a pointer and a length per symbol, 6 bytes
  less per symbol on 32-bit targets (ADR 0223).
