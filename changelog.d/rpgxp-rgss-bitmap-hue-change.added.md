- **`RGSS::Bitmap#hue_change` is now implemented.** It rotates every pixel's hue by
  the given number of degrees (an RGB → HSV → RGB pass that preserves saturation,
  value and alpha, matching RMXP), so scripts that recolour battlers/tilesets by hue
  work. A hue of 0 (mod 360) is a no-op. Covered by a `mruby-rgss/test` unit test
  (Bitmap ops run headless). This was the last missing `Bitmap` method — `Bitmap` is
  now complete for the stock scripts. See `docs/rpgxp-rgss-api-gap.md`.
