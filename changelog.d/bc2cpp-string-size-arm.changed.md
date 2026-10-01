- bc2cpp (closed world): `String#size` and `String#length` are now called directly
  behind an exact-String arm (audited `NativeCoreDirect` rows, ADR 0291), after the
  generated Array/Hash arms of the same site. The other container sends in the
  wio build turned out to be the else arms of switches that already exist; see the
  ADR for the survey.
