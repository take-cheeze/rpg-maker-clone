- **bc2cpp**: a compiled `rescue` region's try body now receives only the
  values it reads (`RESCUE_CTX_PRUNE`, `BC2CPP_RESCUE_CTX_PRUNE=0` turns it
  off), and one shared call runs the protected body and sets `$!`
  (`RESCUE_PROTECT_FOLD`, `BC2CPP_RESCUE_PROTECT_FOLD=0`). The Wio Terminal
  image is 3.1 KB smaller.
