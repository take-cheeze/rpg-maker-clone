- **bc2cpp**: three class-pool rules found while tracing what drops
  `Game::Battle::Combatant#@states`. An `Array#+`/`Array#-` operator on an
  exact Array is typed as the Array its native returns (OPERATOR_SENDS,
  `BC2CPP_OPERATOR_SENDS=0`); a setter pool skips `x=` sites whose receiver
  reaches another class's setter (SETTER_RECEIVER_FILTER,
  `BC2CPP_SETTER_RECEIVER_FILTER=0`); and a `new` with more than 14 arguments,
  which mrbc packs into one Array, is a constructor site again (PACKED_NEW,
  `BC2CPP_CTOR_PACKED=0`), so `Combatant#initialize` and six more `Combatant`
  ivars are pooled.
