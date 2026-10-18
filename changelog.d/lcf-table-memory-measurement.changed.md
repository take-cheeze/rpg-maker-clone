- **Save-state tables**: the eager `LCF::Schema` build is measured on a 32-bit
  `mrb_int` VM (about 12 KB of extra heap against the old lazy form, host
  measurement); see `docs/lcf-schema-memory.md`.
