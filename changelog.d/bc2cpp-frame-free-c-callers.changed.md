- **bc2cpp closed build:** the frame-free native call now also applies when C code calls a found method, such as the
  `initialize` a construction runs; the host sweep's frame pushes fall from 5.6M to 1.8M.
