- The RTP a project is given now follows its maker, and its own `Game.ini`.
  RPG Maker VX and VX Ace projects were handed the **RPG2000** RTP path — a
  directory that can never hold their assets — because only the RPG2000 and XP
  registry keys were wired up. Each RGSS generation registers its RTPs under its
  own key (`Software\Enterbrain\RGSS` for XP, `RGSS2` for VX, `RGSS3` for VX
  Ace), and the value to read there is the RTP *name* the game asks for in
  `Game.ini` (`RTP1=` for XP, `RTP=` for VX / VX Ace), so a project shipped
  against a non-stock RTP resolves too instead of falling back to the default
  name.
