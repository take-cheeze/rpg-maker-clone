- **bc2cpp**: a compiled class's ivar slot table names each ivar by its
  presym id instead of an `"@name"` string, and its entries shrink from 12 to
  8 bytes (Wio: -8.9 KB flash). `MRB_DATA_IVAR_BY_NAME=1` builds the earlier
  form.
