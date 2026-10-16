- **bc2cpp** (ADR 0470): more literal-block iterator sends call the compiled block-taking body directly. An
  implicit-self `loop { }` calls mruby's compiled Kernel#loop when the closed world proves nothing else can answer
  it; `each_char`/`each_line`/`each_byte` on an unproven receiver get an exact-String arm; an Integer literal
  receiver (`2.times { }`) keeps no dynamic else; and a method using `s.each_line { }` with captured locals is no
  longer left interpreted. Natively, `Bitmap#draw_text` reads RGSS::Font's attributes without a call while they are
  the plain `attr_accessor` readers, and a Bitmap copy dups its font through Kernel#dup's own function. Every new
  path falls back to the send the site already had. Check `scripts/bc2cpp/block_iterator_direct_check.rb`.
