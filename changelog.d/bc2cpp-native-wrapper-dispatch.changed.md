bc2cpp now resolves RGSS native wrapper calls through frame independent bodies
and exact runtime class guards, including Bitmap drawing methods and Sprite,
Window, and Viewport setters. Calls whose receiver class cannot be proven at
compile time still retain ordinary dispatch for other runtime classes.
