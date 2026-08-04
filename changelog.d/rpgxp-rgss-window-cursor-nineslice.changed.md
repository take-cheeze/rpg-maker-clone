- **`RGSS::Window`'s selection cursor is now a crisp 9-slice.** Instead of stretching
  the whole 32×32 windowskin cursor region over `cursor_rect` (which blurred the
  border), it draws a 9-patch with 2px corners (matching RMXP/mkxp's `buildFrame`):
  the four corners copy 1:1, the four edges stretch along one axis and the centre
  fills the rest, so the selection box keeps a sharp border at any size. The blink
  animation is unchanged. See `docs/rpgxp-rgss-api-gap.md`.
