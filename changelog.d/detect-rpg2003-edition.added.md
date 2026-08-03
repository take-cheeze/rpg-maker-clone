- The LCF parser can now **detect the RPG Maker edition of a project** from the
  file itself: `LCF::Database#maker` (and `#rpg2003?`) return 2003 or 2000 based
  on the presence of the RPG2003-only Classes section (chunk 30), independent of
  the compile-time `LCF::MODE`. A new `LCF::Array1D#key?` primitive reports
  whether a chunk id was physically present, distinguishing an absent optional
  section from an empty one. `scripts/lcf_testbed_check.rb` now reports the
  detected edition per game and, for a 2003 database, validates that the Classes
  table decodes and every actor's `class_id` resolves to a real class — verified
  against real 2003 projects (Song-of-the-Sea, 25 classes; mtf-meido-action, 18)
  alongside the RPG2000 Nepheshel data. See ADR 0013.
