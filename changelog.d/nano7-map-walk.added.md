- **iPod nano 7th generation (homebrew)**: a minimal, from-scratch map-walking
  app (`app/nano7/rpg2k_walk`, see ADR 61) for jailbroken iPod nano 7G
  hardware via the [NanoApps](https://github.com/nfzerox/NanoApps) SDK. A new
  host-side exporter (`scripts/export_nano7_map.rb`) converts a real RPG
  Maker 2000/2003 map — tiles, autotiles and passability — into a compact
  binary the on-device app reads directly; this is a separate, non-mruby
  engine (NanoApps' ~500 KB app-image ceiling rules out this repo's mruby/RGSS
  stack), so it walks one static map with no events, battle or menus.
