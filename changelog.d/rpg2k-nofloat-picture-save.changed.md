- **Pictures:** a picture's position, zoom, opacity and tone are kept in fixed
  point internally, and converted to save doubles only when a save is written
  or read. Opacity is saved as a whole-percent transparency, so a fractional
  opacity round-trips to within about 0.0025 px rather than exactly.
