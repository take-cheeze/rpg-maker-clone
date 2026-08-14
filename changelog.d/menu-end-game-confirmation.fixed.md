- **The field menu's End Game command now opens a Yes/No confirmation
  instead of quitting outright on the first press.** Found via the LCF
  field audit (`scripts/rpg2k_field_audit.rb`), which flagged
  `term.end_game_confirm` (Term chunk 21 field 151) as a field the schema
  parses and nothing in `mruby-rpg2k` ever reads. `Scene::Menu#select_command`
  played the Decision SE and called `@parent.return_to_title` directly, with
  no confirmation of any kind. EasyRPG Player's actual C++ source shows real
  RPG_RT never quits that fast: `Scene_Menu::UpdateCommand`'s `case Quit:`
  (`src/scene_menu.cpp`) plays Decision and pushes `Scene_End`, never
  touching the title itself; `Scene_End::vUpdate` (`src/scene_end.cpp`) plays
  Decision on *either* option and only "Yes" (`BgmFade(400)` then
  `ReturnToTitleScene`) goes anywhere — "No" and Cancel both just
  `Scene::Pop()` back to the menu; `Scene_End::CreateCommandWindow` defaults
  the cursor to index 1 ("No"), and `CreateHelpWindow` draws its prompt from
  `terms.exit_game_message` (this schema's `term.end_game_confirm`),
  falling back to "Do you really want to quit?" when the database leaves it
  blank. `Scene::Menu` now opens an in-scene Yes/No prompt on End Game
  (cursor defaulting to "No") built from `term(:end_game_confirm, ...)` /
  `term(:yes, ...)` / `term(:no, ...)`; confirming "Yes" calls
  `RGSS::Audio.bgm_fade(400)` before `@parent.return_to_title`, while "No"
  and Cancel both just close the prompt back to the command list. Covered by
  new `scripts/rpg2k_scene_check.rb` checks (selecting End Game opens the
  prompt without touching the title, cursor starts on "No"; confirming "No"
  and cancelling both leave the title alone; confirming "Yes" fades the BGM
  and returns to the title), confirmed to fail against the pre-fix code —
  the old check asserted the opposite, that End Game "hands control back to
  the app immediately, with no confirmation message to dismiss first" — now
  replaced.
