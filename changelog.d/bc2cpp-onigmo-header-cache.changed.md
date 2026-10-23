- **bc2cpp:** the closed-world analysis overlay reuses the Onigmo header from the
  scan cache, keyed on the tarball's digest, so a rebuild no longer runs `tar`
  for it. The generated headers are byte-identical.
