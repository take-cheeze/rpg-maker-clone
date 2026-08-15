- **`scripts/rpg2k_field_audit.rb`** — the "does the runtime name this field"
  glob only scanned `mruby-rpg2k/mrblib/*.rb`, missing the entire `scene/`
  subdirectory where most gameplay logic actually lives (12 of the runtime's
  15 `.rb` files). That made the survey's "never named by the runtime" list
  full of false positives — fields read from a `scene/` file the glob never
  scanned. Made the glob recursive (`**/*.rb`) so it scans the whole tree; no
  runtime or gameplay behaviour changed, only the survey script's accuracy.
