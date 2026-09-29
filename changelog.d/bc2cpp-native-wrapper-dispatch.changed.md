bc2cpp now resolves RGSS native wrapper calls through frame independent bodies
and exact runtime class guards, including Bitmap drawing methods and Sprite,
Window, and Viewport setters. It also emits registered core native expressions
without a dispatch fallback when a fresh receiver has a proven exact class.
Calls whose receiver class cannot be proven at compile time still retain
ordinary dispatch for other runtime classes.
