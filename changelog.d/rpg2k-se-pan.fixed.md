- **RPG2000/2003 sound effects now honour their own configured pan (balance)
  instead of it being unimplementable.** Cycle #220's SE-struct sweep found
  every `Audio.se_play` call site consistently dropping the LCF `SE` struct's
  field 5 (`balance`, `mruby-lcf/mrblib/schema.rb`) -- but, unlike the `BGM`
  struct's own balance (cycles #202-#220), left it alone: `RGSS::Audio.se_play`
  had no pan argument at all to forward it to, and adding one meant real
  native (`.cxx`) work, not just Ruby-side plumbing. This cycle adds it.
  `RgssAudioBackend::se_play`/`se_play_mem` (`include/rgss_audio.hxx`) grow a
  4th `pan` argument; `src/sdl_audio.cxx`'s `start_se` calls
  `Mix_SetPanning(ch, left, right)` directly on the channel `Mix_PlayChannel`
  just handed back, right after the existing `Mix_Volume` call -- genuine
  per-effect panning, not `bgm_pan`'s `MIX_CHANNEL_POST` master-bus
  workaround (SDL_mixer's `Mix_SetPanning` works on an ordinary `Mix_Chunk`
  channel directly; the postmix trick is only needed to reach a `Mix_Music`
  stream at all). `RGSS::Audio.se_play`/`_se_play_mem` (`mruby-rgss/`) gain
  the same optional 4th argument, defaulting to 50 (centre) so no real RGSS
  script call site (which never passes one) changes behaviour. Every RPG2000
  call site that builds an `SE` struct's audio now forwards its `balance`
  through this new argument instead of silently dropping it: the Play Sound
  Effect (11550) event command (`Interpreter#play_audio`'s own comment had
  documented `balance` as a parameter here for cycles without it ever being
  read), every system-SFX slot (`Scene::Base#play_system_se`/`#db_system_se`
  -- the database-default path never read `.balance` off the LCF struct at
  all, though the Change System SFX (10670) override path already tracked
  it), a Move Route's "Play SE" sub-command (`MapWorld`/`VehicleWorld
  #play_sound`, previously accepted and immediately discarded as a
  `_balance` parameter), a battle animation's own timing SE
  (`#play_animation_se`), a Switch/Escape skill's own `sound_effect` field
  (`Scene::SkillMenu#play_skill_sound_effect`), the title screen's cursor SE
  (`Scene::Title#play_cursor_se`), and RPG2003's terrain footstep SE
  (`Scene::Map#play_terrain_footstep_se`). Covered by new
  `scripts/rpg2k_logic_check.rb`/`scripts/rpg2k_scene_check.rb` checks
  (confirmed to fail pre-fix, one file at a time, restoring each from `git
  show HEAD:<path>`) and `mruby-rgss/test/test.rb`'s existing SE-resolution
  check, extended to assert the new argument. No wine session run this
  cycle (as with every prior BGM-pan cycle, this sandbox has no genuine
  RPG_RT.exe or real audio device); verification is internal consistency
  only -- the native `Mix_SetPanning` call itself, and any interaction with
  `bgm_pan`'s own pre-existing `MIX_CHANNEL_POST` compromise when both a
  game's BGM and an SE are simultaneously panned off-centre, is unverified
  against genuine hardware/DirectSound behaviour.
