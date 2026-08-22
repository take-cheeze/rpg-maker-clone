- Fixed `document.body.getBoundingClientRect()` (and other stub DOM elements)
  always reporting an all-zero rect instead of the actual viewport size, in
  the shared MV/MZ DOM shim (`mruby-mvjs/src/mvcanvas.cxx`). A real browser's
  reports the actual viewport, and some MV/MZ corescript builds read a
  project's initial screen resolution from this rect rather than (or
  alongside) `window.innerWidth`/`innerHeight`; an all-zero stand-in silently
  fed those a 0x0 resolution. Now matches `window.innerWidth`/`innerHeight`.
