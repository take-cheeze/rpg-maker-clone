- **RPG2000 sample-game analysis** — a new `scripts/analyze_game.rb` loads the
  pure-Ruby LCF parser under CRuby and walks a game's `RPG_RT.ldb` common events
  and `Map*.lmu` event pages, reporting database entity counts and a classified
  event-command histogram (implemented / no-op-by-design / genuine feature gap),
  move-route usage and per-page trigger/move-type breakdowns (`--json`
  supported). `docs/rpg2000-sample-analysis.md` writes up the collection (7
  `Sample*` + 32 ツクールコンパク `Extra*` contest games) and a deep dive on
  Sample2/Sample3: the control-flow/variable/switch core is done and dominates
  real usage (Sample3's common events are ~99.5 % correctly handled once
  comments/blank lines are excluded), and the genuine gaps cluster into
  pictures, screen effects, message face/options, and battle entry — used to
  prioritise interpreter work.
