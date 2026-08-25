- **RPG2k: call-only common events decode lazily instead of on every map
  transition.** `Game::CommonEvent.load` (`mruby-rpg2k/mrblib/game.rb`) used
  to eagerly decode every common event's full command list on every single
  `Scene::Map` construction, regardless of trigger type -- only auto-start
  and parallel-process common events are ever scanned automatically, so a
  call-only one (invoked solely via a Call Event command, the common case
  for reusable subroutines in a real project) paid a full decode -- one
  mruby object per command, plus a nested parameter array each -- for
  nothing, every time any map loaded. Auto-start/parallel common events
  still decode eagerly (they're genuinely needed every visit); a call-only
  one now keeps its raw, undecoded database chunk and decodes-and-caches it
  the first time (if ever) a Call Event actually resolves that id
  (`EventResolver#common_event_commands`,
  `mruby-rpg2k/mrblib/scene/base.rb`). On the PSP, where mruby's whole live
  object graph shares a fixed 12 MB arena
  (`docs/adr/0047-psp-memory-budget.md`'s P2), this directly shrinks the
  jump `Scene::Map` costs on entry for any project with call-only common
  events it doesn't happen to invoke on a given visit.
