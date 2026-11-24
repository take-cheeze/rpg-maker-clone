- **RPG_RT.ldb is read on demand**: chunks and table rows of 2 KB or more stay
  in the file until a scene uses them, so a database larger than the device's
  RAM (Nepheshel's is 1.3 MB) no longer has to fit in it. A host that defines
  `LCF_EAGER_DATABASE` true reads it whole as before.
