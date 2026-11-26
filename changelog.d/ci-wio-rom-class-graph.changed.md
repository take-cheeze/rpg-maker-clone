- **CI's Wio firmware keeps its boot classes in flash**: the `wio` job dumps
  the ROM class graph under Renode from the same build, fails unless a boot on
  it leaves the same graph, and links it into the uploaded `wio` and
  `wio_renode_game` firmware (about 21 KB less heap at the title, about 16 KB
  more internal flash).
