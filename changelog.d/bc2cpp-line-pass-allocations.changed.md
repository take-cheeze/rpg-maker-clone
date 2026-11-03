- **bc2cpp** compiler: the dead-statement and owner-call-direct passes walk a method's C++ by byte offset instead of
  splitting it into per-line Strings, methods without native arguments share a frozen type list, RegisterFlow reads
  clean definitions without a MatchData, strict hints replace the dispatch without building a Regexp, and the loop
  recognizers' layout lambdas are constants. The sealed Optcarrot compile allocates about 4.4% fewer host objects;
  the generated C++ is unchanged. See [line-pass allocations](docs/bc2cpp-line-pass-allocations.md).
