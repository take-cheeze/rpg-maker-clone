- **Typed setters for the save schema.** `LCF::SaveTyped` records now have a generated
  `save_<field>=` for every one of the 251 save fields, which checks the value's class
  against the field's schema type (naming the field when it is wrong) and writes it through
  the same schema encoder as before, so the bytes are identical. Not shipped on wio
  (23.5 KB of bytecode); wio gains 105 bytes.
