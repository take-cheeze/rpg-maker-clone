- **`\^` inside a Show Choices label is confirmed already inert, no code
  change needed** — a standalone choice window computes `:auto_close` from
  its labels but `Scene::Map#drive_message` never reads it for a choice
  window (only ever for a plain text message), and a choice list merged
  onto a preceding Show Text discards the scanned `:auto_close` outright
  before a reveal object is even built. Either way a choice list can only
  ever close on player input, matching real RPG_RT. Covered by two new
  `scripts/rpg2k_scene_check.rb` checks, both confirmed to fail against a
  temporarily-patched build that makes `\^` auto-close a choice window.
