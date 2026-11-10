- mruby: bump `3rd/mruby` to the fork's found-method sends and per-type memos in core C (`hash`, `initialize_copy`,
  `convert_type`, `IO.sysopen`; the Hash `default`, Array-key `eql?` and `respond_to_missing?` lookups), and
  `3rd/nfcxx` to the matching bc2cpp audit pins. Over the Nepheshel sweep, by-name sends fall from 24,340 to 21,882 and
  method-table searches from 14.6M to 4.9M.
