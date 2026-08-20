- **UI:** The selection-cursor highlight in every window now blinks between
  the windowskin's two cursor art blocks while the window is active --
  matching RPG_RT's own `Window::Update`/`Window::Draw`. Previously it drew
  from a single, permanently-static source rect; a windowskin whose two
  cursor blocks differ (the bundled test skin's happen to match) would show
  a static highlight instead of blinking.
