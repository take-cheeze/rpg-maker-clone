- **Wio:** the Enter Hero Name grids (letters, hiragana, katakana) are built
  when the widget opens instead of living in RAM as constant Arrays of
  Strings for the whole game, which leaves about 6 KB more heap on the
  192 KB board.
