- `scripts/mz_testbed_check.rb` no longer fails a real MZ project for shipping
  an empty `System.partyMembers`. `Game_Party.setupStartingMembers` just
  filters the list through `$gameActors`, which silently skips an id with no
  matching actor — an empty array is not a boot hazard, and a real
  freem.ne.jp game that ships one (its first party member arrives via an
  intro event's Change Party Member command) boots to `Scene_Title`, New
  Game and a full map walk with no issue. The check now only requires an
  `Array`, still flagging a listed id that Actors.json doesn't have.
