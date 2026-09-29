- **bc2cpp** decodes instructions from mrbc's RITE binary (`mrbc -g -o`) instead
  of parsing `mrbc -v` disassembly text; generated output is byte-identical
  (`BC2CPP_TEXT_LOADER=1` keeps the text loader, ADR 0249).
