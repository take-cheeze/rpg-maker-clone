- **bc2cpp closed build:** a native method whose C body reads its call frame only through the argument readers now
  runs without pushing a frame, chosen from the body itself rather than a list of names; the host sweep's frame pushes
  fall from 104.7M to 1.8M with the same results, errors and backtraces.
