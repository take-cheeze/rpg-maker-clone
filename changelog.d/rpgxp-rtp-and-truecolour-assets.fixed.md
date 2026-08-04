- RPG Maker XP projects now draw their real RTP graphics instead of
  placeholders, and truecolour art draws in the right colours. Four fixes, all
  found by diffing our frames against the genuine RGSS runtime under wine
  (`scripts/compare-rpgxp-wine.bash`): the XP RTP registry key
  (`Software\Enterbrain\RGSS\RTP\Standard`) is now what an XP project's
  `RTP_DIR` resolves to (only the RPG2000 key was ever consulted, so no XP asset
  could be found); `.jpg` joined the Bitmap search extensions (the XP RTP stores
  title backgrounds as JPEG and windowskins as PNG); stb's decoded pixels are
  swapped into LVGL's B, G, R order explicitly, since the vendored BGR hack only
  covered indexed PNGs and left every truecolour PNG and JPEG with red and blue
  exchanged; and a bitmap's pixel format now follows the channel count actually
  requested from the decoder, so an RGBA image loaded opaque no longer fills a
  4-byte-per-pixel bitmap from 3-channel data. RPG2000 rendering is unchanged
  (its title screen is byte-identical before and after).
- The RPG Maker XP title screen's command window is 192 wide, matching RMXP's
  `Window_Command.new(192, ...)`; at 240 it sat too wide and too far left of the
  genuine runtime's window.
