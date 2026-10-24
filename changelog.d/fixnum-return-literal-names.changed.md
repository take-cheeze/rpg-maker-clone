- **bc2cpp**: `Game::Actor#battle_row`, `#atb_gauge` and `Game::Party#effective_int`
  now carry their declared Integer return fact. Duck-typed callers probe the
  setters (`respond_to?(:battle_row=)`) and the Equip screen dispatches its
  stat rows on the term key, so no Symbol spells these readers any more and
  FIXNUM_RETURN_PROOF no longer refuses them (three fewer TC1010 notes).
