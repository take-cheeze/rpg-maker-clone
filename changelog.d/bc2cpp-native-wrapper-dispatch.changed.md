bc2cpp now resolves proven RGSS `Bitmap#stretch_blt`, `Bitmap#copy_blt`, and
`Bitmap#draw_text` calls through frame-independent native bodies guarded by
exact runtime class identity.
