- **The field message window's "avoid hiding the hero" auto-relocation now
  uses RPG_RT's real thresholds and reference point.** Ported from a
  reference implementation, not independently confirmed against genuine
  RPG_RT under wine: the real
  zone boundaries are 112px and 160px (not this engine's earlier
  `SCREEN_H / 2` = 120px approximation), measured off the hero's *feet*
  (the tile's bottom edge), not its centre. More significantly, the
  auto-relocation is not simply "top when low, bottom when high" regardless
  of the configured Message Options preference the way this engine always
  treated it -- it is a genuine three-way switch keyed on that preference
  (Up/Center/Down), each with its own thresholds and behavior, including a
  Middle outcome the Center preference alone can produce while unpinned.
