- **Fleeing a battle now says so, in the database's own words.** The 用語
  table's `escape_success` / `escape_failure` fields were parsed but never
  shown: a successful flee closed the battle with no message at all, and a
  failed one logged only to the console. A successful Escape now routes
  through the same result window a win or a loss already shows (worded from
  `escape_success`, falling back to composed English when the database leaves
  it blank), so it reads and pauses for confirmation exactly like a Victory or
  Defeat rather than snapping straight back to the map. A failed attempt
  banners `escape_failure` low on screen — the same transient window a landed
  hit already banners on, now factored out as `#show_battle_banner` so both
  share it — while the round continues around it. Covered by new checks in
  `scripts/rpg2k_scene_check.rb` (a successful flee opens the result window
  and shows the escape_success wording before running the event's Escape
  handler).
