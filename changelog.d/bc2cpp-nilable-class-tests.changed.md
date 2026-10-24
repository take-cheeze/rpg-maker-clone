- **bc2cpp**: a receiver the exact-class flow proves to be one Ruby class no
  longer goes through the RGSS native arms for names a native also answers
  (`x`, `y`, `width`, `dispose`, ...), and a nil-or-K receiver takes the nil
  test and K's direct call whenever that removes class tests. On the closed
  world this removes 25% of the runtime class tests (10,067 to 7,515) and 65 of
  the 104 by-name sends. `BC2CPP_RUBY_EXACT_PAST_NATIVE=0` and
  `BC2CPP_NILABLE_CLASS_TESTS=0` turn the rules off.
