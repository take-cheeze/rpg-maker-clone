- **LCF loading allocates less.** BER numbers are appended to the output string
  in place instead of being built from temporary arrays and strings, which cuts
  about 230k heap objects from a battle start in Nepheshel.
