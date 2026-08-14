- **rpg2k message-window narration in Zundamon's (ずんだもん) voice**, opt-in
  via `--zundamon_tts`: each Show Text page's plain, fully-expanded text is
  read aloud as it opens, through a bundled offline VOICEVOX CORE synthesis
  stack (`RGSS::Tts`, `src/voicevox_tts.cxx`) rather than a separate VOICEVOX
  Engine process. The stack (~90 MiB — CORE, its ONNX Runtime, the Open JTalk
  dictionary and Zundamon's voice model) is fetched by
  `scripts/download-voicevox-zundamon.bash` rather than committed; with
  nothing downloaded (or on a platform this feature does not cover) the flag
  logs why and the game runs exactly as it would without it. See
  `docs/adr/0046-zundamon-message-narration.md`.
