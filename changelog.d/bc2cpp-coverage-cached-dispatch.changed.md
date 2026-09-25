- **bc2cpp coverage reports** now count cached `bc2cpp_send` and block-carrying
  dispatch sites by resolving the generated symbol table, instead of reporting
  zero for the already-generated code and producing negative totals.
