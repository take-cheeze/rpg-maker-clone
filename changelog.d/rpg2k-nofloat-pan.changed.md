- **Screen pan:** the pan offset, targets and step are kept in 1/16-pixel
  integers instead of Floats, so a no-Float build can run them. Positions and
  speeds are unchanged; save files read and write the same values.
