- **bc2cpp**: native code that reads a compiled attribute reader (the RGSS::Font attributes behind every text draw)
  calls it without pushing a call frame. The closed host build makes 31% fewer framed calls (705,578 to 489,230 over
  the Nepheshel sweep).
