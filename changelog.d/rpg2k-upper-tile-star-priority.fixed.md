- **An upper-layer chipset tile now only draws in front of the hero/events
  when the editor's "star" (above-hero) flag is actually set on it,** instead
  of every tile placed on the upper layer being treated as always-above.
  RPG_RT reads the same `ABOVE_BIT` (0x20) this renderer already used for
  upper-tile passability (`Game::ChipSet#upper_flags`/`ABOVE_BIT`) to decide
  draw order too: an unstarred upper tile — the majority of a chipset's upper
  tiles, meant to be walked *against* rather than *under* (furniture, shop
  counters) — composites in the same buffer as the lower layer, so a
  character standing on or against it still shows through. Confirmed pixel-
  perfect against a genuine RPG_RT.exe under wine: Nepheshel's opening lies
  the hero across a 3-tile bed graphic (headboard / mattress / footer), none
  of whose tiles are starred, so his head now clears the pillow the way
  RPG_RT's does — a separate above-hero map event supplies the small pillow
  graphic that covers him from the neck down. Treating every upper tile as
  always-above left him fully invisible instead of tucked in. New
  `Game::ChipSet#elevated?` reads the flag; covered by new checks in
  `scripts/rpg2k_logic_check.rb` and `scripts/rpg2k_scene_check.rb`.
