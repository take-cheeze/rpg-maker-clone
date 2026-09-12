- The opt-in (`RPGMAKER_BC2CPP=1`) AOT compiler's `.singleton` owner
  support picks off the small remaining scraps a real, unrestricted
  diagnostic run found but the two prior `.singleton`-coverage rounds
  didn't have time for: 24 more real class methods across 12 tiny
  `mruby-rpg2k` modules (`Game::MoveType.singleton` (4),
  `Game::MapAccess.singleton` (4), `Game::Parallax.singleton` (3),
  `Game::MessagePalette.singleton` (3), `Game::MapBgm.singleton` (2),
  `Game::BattlePage.singleton` (2), `Game::WindowCursor.singleton`,
  `Game::Message.singleton`, `Game::EventPage.singleton`,
  `Game::CharSet.singleton`, `Game::Backdrop.singleton`, and
  `RPG2k::Scene.singleton` -- one each), all registered in
  `mruby-rpg2k-compiled`.

  Also closes out `RGSS::Font.singleton#exist?` -- the one `.singleton`-
  owned method left open as a known-good candidate by an earlier round's
  own "RGSS::Font investigated, and NOT added" follow-up, written before
  `.singleton` emission existed at all -- now a real, registered
  `mrb_define_class_method` entry point in `mruby-rgss-compiled`, a nice
  full-circle validation of that mechanism.

  Three tiny leftover instance-method classes/reopenings are registered
  too: `RPG2k::Scene::Map::LRUBitmapCache` (5 of its 6 real methods --
  `#initialize`, `#[]`, `#[]=`, `#key?`, and the private `#bitmap_bytes`;
  its `#evict_lru_until_within_budget` stays interpreted, a real block
  body), `RGSS::ErrorReport::Tee#initialize`, and `Array#include?` (a
  plain-index-loop reopening of the native `Array` class, replacing
  mruby's own block-allocating `Enumerable#include?` fallback -- the
  first bare core class ever named in one of these gems' own `owners:`).
  `StringIO#ungetbyte` (a similar reopening of the native `StringIO`
  class) is registered in `mruby-lcf-compiled`, this project's first
  cross-`3rd/`-submodule compiled override.

  All ~29 new entry points were re-verified compiling clean in a real,
  per-gem `ONLY_OWNERS` run (not just the unrestricted whole-program
  diagnostic that first found them). Verified with a full before/after
  diff across all three compiled gems, an actual `RPGMAKER_BC2CPP=1`
  `cmake`/`ninja` build of `libmruby.a`, and `nm` on the real compiled
  objects: every already-shipped owner's own generated code, ivar
  embedding decisions, and whole-program MONO/POLY registry entry count
  are byte-for-byte unchanged; the only new symbols are the new methods'
  own `_impl`/entry-wrapper pairs.
