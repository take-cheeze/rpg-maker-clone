- bc2cpp: compiled engine code no longer tests the frozen flag on an embedded
  ivar store or synthesized attr_writer (the world now proves no engine object
  is ever frozen), and skips the write barrier where the stored value is
  proven an immediate. Wio flash shrinks by about 19 KB.
