- **XP / VX / VX Ace** three more real gaps found continuing to boot a real
  VX Ace game past its previous walls, all fixed: a freshly constructed
  `Window`'s `contents` started as Ruby `nil` in `mruby-rgss`'s native
  `window_init` instead of a real `Bitmap`, so real RGSS3's own stock
  `Window_Base#create_contents` (`contents.dispose`, run by every `Window`
  a game ever builds) raised `NoMethodError` on the very first window any
  VX Ace game constructs. `Audio.bgm_play` rejected RGSS3's 4th (`pos`,
  resume-playback-position) argument that a real `RPG::BGM#replay` and
  volume-control add-on scripts call with — now accepted and warned about
  once rather than raising `ArgumentError` (no backend here seeks a
  mid-track position, so the track plays from its own beginning).
  `RPG::CommonEvent` had no `#autorun?`/`#parallel?`, which real RGSS3's own
  stock `Game_Map#setup_autorun_common_event`/`#parallel_common_events` call
  directly — every VX Ace game raised `NoMethodError` the moment a player
  pressed New Game (VX Ace-only; confirmed XP's own stock scripts never call
  either predicate).
