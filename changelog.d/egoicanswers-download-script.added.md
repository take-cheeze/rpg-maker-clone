- `scripts/download-egoicanswers.bash` — a real RPG Maker **MZ** test bed
  ("Egoic Answers" / エゴイックアンサーズ！, fgamearchives) with both
  `hasEncryptedImages` and `hasEncryptedAudio` set, exercising the same
  encrypted-asset path `mz_encrypted_check.bash` otherwise only drives against
  a *derived* project. The upstream archive is a full NW.js-packaged build
  (~900 MB, stored rather than deflated); the script extracts only the actual
  project directories (`data/`, `img/`, `audio/`, `js/`, `effects/`,
  `fonts/`) and skips the bundled Chromium/NW.js runtime, which this repo's
  engine has no use for. `ruby scripts/mz_testbed_check.rb data/EgoicAnswers`
  passes clean. Not yet wired into CI, given its size relative to every other
  downloaded test bed here.
