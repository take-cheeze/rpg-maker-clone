- **bc2cpp**: an owner call on an exact Integer, Array, Hash or Range now calls the compiled mruby core body
  directly when that class answers the name with one (`x.abs` on an Integer reaches `Numeric#abs`). The closed host
  build makes 31% fewer framed calls (705,578 to 482,876 over the Nepheshel sweep).
