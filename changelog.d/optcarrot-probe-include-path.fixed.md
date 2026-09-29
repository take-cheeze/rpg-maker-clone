- The optcarrot bc2cpp probe adds the repo `include/` directory to its generated gem,
  so bc2cpp's emitted `#include "rgss_construct.hxx"` resolves (CI
  `optcarrot-benchmark` failed with a missing-header error).
