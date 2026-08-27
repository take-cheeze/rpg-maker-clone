- `Game::State#to_lsd` now accepts an optional database handle and, when
  given one, resolves an uncustomized vehicle's `charset_name`/
  `charset_index` (chunk 105/106/107 fields 73/74) off the database's own
  System boat/ship/airship_name/_index — the same fallback `Scene::Map`'s
  own `#vehicle_charset`/`#vehicle_charset_index` already apply for
  rendering — instead of leaving those two fields absent. `main.rb`'s own
  save export now passes its database through. A live Change Vehicle
  Graphic override (or one restored from a prior `.lsd`) still wins over
  the fallback, and a caller with no database handle (tests, tools) keeps
  the prior absent-when-uncustomized behavior.
