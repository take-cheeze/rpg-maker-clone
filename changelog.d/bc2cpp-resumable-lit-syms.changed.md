- bc2cpp: the resumable and C++ Fiber runtimes stop interning the same few names on every step. Literal symbols are
  cached per call site (`BC2CPP_LIT_SYM`, reused only while the state still names that id the same), a resumable frame
  is recognized by its data type instead of a class lookup by name, the last suspension's block-call flag is a field of
  the frame, and a new frame's registers are filled with one resize. The optcarrot probe's compiled build: 1.59 s to
  1.17 s for 180 frames (hot path 114 to 160 fps).
