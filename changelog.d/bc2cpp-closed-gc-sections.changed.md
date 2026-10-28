- **The closed bc2cpp build compiles one section per function and object**
  (`-ffunction-sections -fdata-sections`), and `scripts/bc2cpp/trace_host.bash`
  links its host with `-Wl,--gc-sections`, as the wio and maix builds already
  link theirs. The host now keeps only the code it reaches: a C function whose
  method-table entry the closed build leaves out, or a compiled entry nothing
  registers, is dropped. The host's text goes from 21.1 MB to 18.5 MB.
