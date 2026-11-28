- **Wio Terminal**: about 11 KB more heap. The compiled engine's per-call-site
  method caches are allocated by the first call of their site (and the native
  ones are shared per method), and the kept-roots record is smaller.
