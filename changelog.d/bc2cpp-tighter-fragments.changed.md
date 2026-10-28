- **bc2cpp**: the closed build keeps about 140 fewer engine methods in its method tables. A string built from a
  pool literal now counts as a possible method name only when the built string itself may reach a lookup
  (FRAGMENT_USES follows a concatenation's result), and the vehicle code reads its database and map-tree fields
  from `Game::Vehicle::SYSTEM_NAME_FIELD` / `SYSTEM_INDEX_FIELD` / `SYSTEM_MUSIC_FIELD` / `INITIAL_FIELDS`
  instead of building `:"#{type}_name"`, whose fragments kept every `*_name`, `*_index`, `*_x` and `*_y` method.
