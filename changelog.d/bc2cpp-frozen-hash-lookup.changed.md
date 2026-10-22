- The bc2cpp type check (report only) types a lookup on a frozen Hash literal with a literal Integer key, such as the
  `Game::ChipSet::ALL_DIRS` bit mask built from `DIR_BIT[2] | DIR_BIT[4]`, as Integer. Codegen is unchanged. Checked by
  `scripts/bc2cpp/frozen_hash_lookup_check.rb`.
