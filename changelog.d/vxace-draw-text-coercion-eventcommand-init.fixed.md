- **XP / VX / VX Ace** two more real gaps found continuing to boot a real
  VX Ace game past its previous walls, both fixed: `Bitmap#draw_text`
  raised `TypeError` when passed a non-`String` text argument, when real
  RGSS3 accepts any object and implicitly stringifies it — a real game's
  own stock `Window_Gold#refresh` draws its gold total (an `Integer`)
  directly, so every VX Ace game whose `Scene_Map` builds its
  `Window_Message` (which builds a `Window_Gold` among its child windows)
  hit this. `RPG::EventCommand` had no constructor at all, so the
  documented `EventCommand.new(code = 0, indent = 0, parameters = [])`
  form real scripts use to synthesize event commands directly (a real
  game's own error-log utility does exactly this) raised `ArgumentError`.
