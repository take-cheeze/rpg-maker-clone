- **bc2cpp:** the NumericFlow bit-to-class maps the code generator keeps
  (`CLASS_TEST_CORE_BITS`, `ESCAPE_FLOW_CLASSES`, `INSTANCE_CORE_BITS`,
  `NUMERIC_SEND_OWNERS`, `RETURN_CORE_CLASS`, `CORE_CONTAINER_BITS`,
  `NUMERIC_MASK_NAMES`) are now derived from one table in
  `tools/bc2cpp/numeric_flow.rb` by name. Each site still names the classes it
  uses, so every map holds exactly the entries it held before.
