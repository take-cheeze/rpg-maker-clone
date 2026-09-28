bc2cpp now resolves RGSS `Bitmap#stretch_blt`, `Bitmap#copy_blt`,
`Bitmap#text_size`, `Bitmap#draw_text`, `Window#openness=`/`#tone=`, and
proven Sprite `#opacity=`/`#tone=` and `Viewport#tone=` calls through
frame-independent native bodies guarded by exact runtime class identity.
