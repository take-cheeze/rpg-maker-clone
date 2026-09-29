bc2cpp now calls frame independent RGSS native wrappers for Bitmap#height,
Bitmap#clear/#rect, Viewport#rect, RGSS data objects' #disposed?, display
objects' #visible, and Sprite/Viewport/Window#update behind exact runtime class
guards. Rect scalar accessors and Color/Tone component getters use the same
guarded direct-call path.
