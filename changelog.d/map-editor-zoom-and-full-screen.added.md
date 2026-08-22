- **The Map Editor (`Scene::MapViewer`) can now zoom and fill a bigger
  screen.** It used to be locked to RPG2000/2003's fixed 320x240 window and
  draw each tile as a single pixel — precise painting on a screen sized up
  via `--width`/`--height` was effectively impossible at that density. **+**/
  **-** now zoom each tile from 1px up to 8px in every mode (pan, Select,
  Edit) — not the RGSS face-button ids X/Y, whose physical keys are already
  spoken for on the SDL desktop backend's own default layout (X cancels, and
  Y is unbound entirely) — and the editor's own window/viewport fills
  whatever `--width`/`--height` was actually configured instead of sitting in
  a fixed 320x240 corner of it. Real gameplay scenes are unaffected and still
  render at RPG2000/2003's authentic resolution, since only this debug-only
  tool has no rendering fidelity to protect.
