- The closed bc2cpp build keeps 11 more core methods as rows outside the method table (`Array#last`, `String#upcase`,
  `#to_f`, ...). Names that only core Ruby, a `3rd/` native or generated literals make dynamic no longer count as
  engine lookups for core rows. The closed host table goes from 684 to 674 entries.
