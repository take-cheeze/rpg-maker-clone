- The coverage report's `rpg2k_game` requirement no longer counts the committed
  `data/maix-hello` fixture as a test bed, so `rpg2k-command-soak` and
  `nano7-map-export` skip (or fail under `--require-needs`) instead of passing
  vacuously. Covered by `scripts/coverage/test_bed_check.rb`.
