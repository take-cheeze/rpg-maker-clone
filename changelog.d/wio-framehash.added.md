- Frame hashes for comparing two builds' pictures: `scripts/wio/renode_game.bash
  --framehash FILE` writes an `FH <frame> <hash>` line per frame of a Renode
  run, the host harness prints them with `BC2CPP_HOST_FRAMEHASH=1`, and
  `scripts/compare/framehash.rb` compares two runs. CI checks that the Wio SD
  title run draws the same frames on its first boot and after a reboot.
