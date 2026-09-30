- `tools/bc2cpp/codegen_send.rb`: the five "can this send be a plain direct call" checks of
  `compile_send` are one documented `direct_callable?(definition, n)`. Generated code is byte-identical
  on the wio game build and on optcarrot. See docs/adr/0287.
