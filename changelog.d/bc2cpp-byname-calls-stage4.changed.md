- **bc2cpp:** Bitmap text drawing reads each Font attribute through the
  method it resolves to, without a second by-name lookup; with the mruby
  fork's `==`/`eql?`/`<=>` and `Class#new` changes this removes ~334K of
  the ~350K by-name calls a closed-build host sweep made. Overrides still win.
