- **A map event page's Timer condition (flags bit `0x20`, "Timer ≤ N
  seconds") is now evaluated instead of being ignored.** A page conditioned
  on the countdown read as always-active regardless of the real Timer1 value.
  `Game::EventPage::TIMER` and `.active?`/`.select` now compare against
  Timer1's live seconds-remaining value (active once it counts down to
  `timer_sec` or below, matching EasyRPG's `Game_Event::AreConditionsMet`),
  threaded through both `Scene::Map` call sites and folded into
  `#page_revision` so a Timer-gated page re-selects the instant the
  displayed second crosses the threshold.
