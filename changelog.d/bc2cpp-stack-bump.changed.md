- **bc2cpp:** bump `3rd/mruby` (frame-free `Array#==`/`Hash#==`, a missing default hook is a no-op) and `3rd/nfcxx`
  (singleton ROM tables count as installed, default hook entries leave the closed table). The closed host table
  shrinks and the `==` frame pushes are gone; no engine behaviour changes.
