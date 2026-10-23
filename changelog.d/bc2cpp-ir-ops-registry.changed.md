- The bc2cpp class/method registry and class-layout analysis now name opcode
  groups through the shared `BytecodeIR::Ops` sets instead of spelling their
  own opcode lists. Generated C++ and analysis output are unchanged.
