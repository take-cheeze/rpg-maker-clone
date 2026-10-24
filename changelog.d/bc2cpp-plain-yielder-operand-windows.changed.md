- **bc2cpp: the plain-yielder proof reads operand windows exactly.**
  `BlockSelf.reads_of` now gives `ARRAY`/`ARRAY2`/`ARYPUSH`/`HASH`/`HASHADD`/
  `ARYCAT`/`HASHCAT`/`STRCAT`/`ARYSPLAT` the registers the VM reads and models
  splat, keyword and `**` sends, instead of treating every register above the
  lowest operand as read and refusing `block.call(*val)`. `Enumerable#collect`,
  `find_all`, `reject`, `any?`, `all?`, `count`, `detect`, `Hash#each`,
  `select` and `reject` become plain yielders, so the closed world builds 309
  instead of 220 blocks in the caller's frame (129 sites still always build a
  heap `RProc`, from 218). Covered by `scripts/bc2cpp/plain_yielder_check.rb`.
