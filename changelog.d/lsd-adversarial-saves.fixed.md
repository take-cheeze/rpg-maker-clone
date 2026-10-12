- **A truncated or corrupt `Save<N>.lsd` is now an empty slot with the reason
  logged, instead of loading half-read or running out of memory.** A chunk whose
  declared length ran past the end of the file used to be read short, so a cut-off
  save loaded with its last field silently garbled; a chunk id such as 2,000,000,000
  asked for a multi-gigabyte array and died with `NoMemoryError`, which the slot loader
  does not catch. Both are refused now, a save missing its hero or inventory record
  names which, and `scripts/rpg2k/lsd_adversarial_check.rb` pins this with unusual-but-valid
  saves (unknown fields, trailing data, every schema field) and truncation and
  corruption sweeps.
