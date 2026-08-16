- **Message window pagination.** A Show Text (or a Show Choices merged onto a
  long Show Text) that runs past the window's four 16px rows now paginates:
  `Scene::Map#open_message` injects a synthetic `:page` pause into
  `Game::TextReveal` at every page boundary so the typewriter stops at the
  bottom of a page, `#draw_message_contents` draws only the current page's slice
  (with a blinking "▼" when more follow), and a confirm advances the page and
  releases the pause instead of dismissing. The choice cursor hides when the
  selection is off the current page and scrolls to keep it visible. Long
  messages no longer clip silently. Covered by three new
  `scripts/rpg2k_scene_check.rb` checks.
