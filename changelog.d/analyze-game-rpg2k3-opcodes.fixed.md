- `scripts/analyze_game.rb` listed Change Class and Change Battle Commands as
  opcodes 12610 / 12710, which liblcf's `EventCommand::Code` enum does not
  define at all — real RPG2003 data carrying either command was therefore
  reported as an unnamed feature gap. They are 1008 / 1009; the table now names
  the whole RPG2003-only block (1005–1009 and the 5001–5005 English-release
  system commands), and the battle-only list covers the three that belong to a
  troop page.
