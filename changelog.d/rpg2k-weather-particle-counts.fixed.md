- **Rain/snow particle counts by strength are now RPG_RT's own real 20/60/100,
  not an invented, denser progression.** Confirmed against EasyRPG Player's
  source (`Weather`'s own `num_rain_or_snow_particles` table): the real
  counts are a literal `{20, 60, 100}` for strength 0/1/2 — not a fixed
  multiple of the lightest strength's own count. The old formula was
  roughly 2.4x too dense at the lightest strength and ~44% too dense at the
  heaviest.
