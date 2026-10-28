- **bc2cpp:** the closed build no longer keeps `Kernel#print`, `puts` and `open`, `IO.popen` and
  `Enumerator#with_object` in the method table. The private-name proof (`CorePrivateRuby`) now reads the generated C++
  as the VM would: a name used only as the receiver-register send of `OP_SEND`, a comment, a registration or the
  `$stderr.puts` of the failure reports is no lookup, and a direct `Owner_name_impl` call makes the body of that owner
  live without making the name reachable. Run-time removals go from 86 to 91.
