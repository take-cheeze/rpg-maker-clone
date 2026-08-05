- Audio files whose extension is spelled in **upper case** now resolve. RPG
  Maker games were authored on Windows, whose filesystem does not distinguish
  `.MID` from `.mid`, so a released game mixes both spellings inside one folder —
  Pray for You's `Audio/BGM` holds ten `.MID` beside eight `.mid`, and on a
  case-sensitive filesystem the upper-case ten were reported as
  `Audio: no BGM found for ...` for files that are right there. Both the disk
  search and the encrypted-archive search now try each known extension in either
  case.
