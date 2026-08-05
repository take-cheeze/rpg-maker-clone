- **A packed RPG Maker release plays its music too.** The other half of reading a
  released game out of its encrypted `Game.rgssad` / `.rgss2a` / `.rgss3a`:
  graphics landed already, and audio needed a change to the backend's C
  interface, because every entry point took a path and a packed track has none.
  - `include/rgss_audio.hxx` grows a `*_play_mem` twin for each of BGM/BGS/ME/SE,
    taking the encoded bytes plus the archive entry name (which becomes the
    sample cache key and names the source in diagnostics). The SDL backend feeds
    them to `Mix_LoadMUS_RW` / `Mix_LoadWAV_RW` through an `SDL_RWops`.
  - The Ruby side mirrors `Bitmap`: after the disk search misses, each kind's
    archive folders are crossed with the same extensions, so a database's bare
    `"Theme1"` finds `Audio/BGM/Theme1.ogg`. Loose files still shadow packed
    ones, as in RGSS.
  - Lifetime is the subtle part. `Mix_LoadWAV_RW` decodes up front so the bytes
    can go, but `Mix_LoadMUS_RW` *streams* from the RWops — and RGSS replays the
    BGM when a music effect finishes, which for an archived track means replaying
    from bytes that must still be around. The backend owns both buffers and frees
    them only where the stream they feed is freed.
  - A build with no audio backend now says so once (`Audio._can_play_mem?`)
    rather than dropping every packed play without a word.

- **Fixed: `Audio.bgm_pos` reported a position for music that had stopped.**
  Halting music does not free the stream, and `Mix_GetMusicPosition` happily
  keeps answering for a stopped one, so `bgm_pos` returned a stale value after
  `Audio.bgm_stop`. A game that saves `bgm_pos` to resume a track later — what
  RGSS2's `$game_system` does — would have written down a position for music that
  was not playing. It now requires `Mix_PlayingMusic()` as well.

  Found by the new probe below passing when it should not have: its packed arm
  was reading the *loose* arm's leftover position, so an empty archive scored
  full marks.

- **An audio probe that can hear the mixer (`audio_probe` ctest).**
  `mruby-rgss/test` installs no audio backend, so every `Audio` call there is a
  no-op and a broken memory path looks exactly like a working one.
  `rpg_maker_clone --rgss_audio_probe` (`RGSS.audio_probe`) plays the same
  generated WAV first from a loose file and then out of an archive, and requires
  loose > 0, stopped == 0, packed > 0 on `Audio.bgm_pos`. The middle step is what
  earns the other two. CI runs it under `SDL_AUDIODRIVER=dummy`, SDL's dummy
  driver, which decodes and mixes with no sound card — so the real decoder runs
  on a machine with no audio device instead of the check quietly not applying.
