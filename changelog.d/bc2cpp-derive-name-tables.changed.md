- **bc2cpp**: `CLASS_TEST_CORE_FIELDS` is now derived from `NativeOwnerMap::CORE_FIELD_OWNERS`, and
  `NATIVE_WRAPPER_CLASS_ACCESSORS` derives each `native_<class>_class` accessor from its class name. The emitted
  output is unchanged. New check `scripts/bc2cpp/native_api_lists_parity_check.rb` asserts that the Ruby
  `FRAME_READERS` and `MRB_API_ALLOW` lists equal those in `scripts/native/binding_facts.py`.
