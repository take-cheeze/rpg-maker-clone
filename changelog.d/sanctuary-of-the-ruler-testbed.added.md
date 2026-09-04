- `scripts/download-sanctuary-of-the-ruler.bash` — a real, fetchable **RPG
  Maker VX Ace** test bed ("Sanctuary Of the Ruler", freeware, fgamearchives),
  the VX Ace counterpart of `download-monodori.bash`. Packed entirely into a
  180 MB `Game.rgss3a` with no loose `Data\`/`Graphics\`, it is picked up by
  the same archive-fallback `discover_games`/`check_archive` taught in
  `rpgvx_testbed_check.rb` for the VX bed. Unlike that one, it checks clean
  with no schema or invariant changes needed: 468 maps, 16 295 event pages,
  155 784 event commands, all parsing through the existing VX Ace schema.
  Not wired into CI: at ~400MB it is well past this repo's 100MB budget for a
  downloaded test bed there, so it stays development/manual-use only, the
  same call made for `download-egoicanswers.bash`.
