- MZ now has sound. rmmz's `AudioManager` exposes the same high-level surface
  MV's audio bridge overrides, so MZ installs `MV::AUDIO_BRIDGE_JS` verbatim and
  drains the same op queue into `RGSS::Audio` each frame (`MZ#pump_audio`) — the
  reason MZ was silent was simply that nobody installed it, not that MZ differed.
  The engine's own calls ride it too: New Game's fade-out emits
  `bgm_fade`/`bgs_fade`/`me_fade` without any probe involved.
- MZ: one MZ-only override was needed on top (`MZ::AUDIO_BRIDGE_EXTRA_JS`).
  `Scene_Boot.start` calls `SoundManager.preloadImportantSounds`, which loads the
  system SEs eagerly through `AudioManager.loadStaticSe` → `createBuffer` →
  `new WebAudio`, and MZ's `WebAudio` fetches with **`fetch`** where MV used
  `XMLHttpRequest` — a global this host does not provide. So the moment a project
  named a system sound, the boot died in `Scene_Boot.start` with "ReferenceError:
  fetch is not defined". Both entry points are now inert; playback still goes
  through the bridged `playSe`.
- MZ: `data/mz-sample` ships an authored `audio/se/Beep.wav` wired to the UI
  sounds, and the new `--mz_audio_test` plays one SE on the map;
  `scripts/mz_boot_check.bash` fails unless the run reports `[MZ-AUDIO]`, so the
  chain (AudioManager → op queue → `RGSS::Audio` → the SDL mixer) is checked end
  to end rather than assumed.
