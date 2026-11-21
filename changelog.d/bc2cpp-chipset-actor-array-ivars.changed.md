- The closed bc2cpp build declares the chipset passability and terrain tables
  and the actor base-stat arrays as `Array?`. The declarations are checked at
  runtime, and they remove 5 owner calls (1331 -> 1326).
