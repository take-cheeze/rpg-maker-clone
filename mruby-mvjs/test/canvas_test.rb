# Tests for the Canvas2D -> RGBA-buffer bridge (milestone M4): document,
# HTMLCanvasElement and the 2D context that PIXI's canvas renderer targets.
# Pixels are read back with __mv_canvasGetPixel (joined to a scalar string so
# MV::JS.eval can return it).

assert 'MV document.createElement("canvas") yields a 2D context; other tags are inert' do
  assert_equal true, MV::JS.eval("!!document.createElement('canvas').getContext('2d')")
  # WebGL is intentionally absent so PIXI falls back to its Canvas renderer.
  assert_nil MV::JS.eval("document.createElement('canvas').getContext('webgl')")
  assert_equal true, MV::JS.eval("typeof document.createElement('div').getContext === 'function'")
  assert_nil MV::JS.eval("document.createElement('div').getContext('2d')")
end

assert 'MV canvas width/height resize the backing buffer' do
  assert_equal 12, MV::JS.eval("var c=document.createElement('canvas'); c.width=4; c.height=3; __mv_canvasWidth(c.__h)*__mv_canvasHeight(c.__h)")
end

assert 'MV canvas fillRect writes opaque pixels within the rect only' do
  MV::JS.eval("globalThis.C=document.createElement('canvas'); C.width=4; C.height=4; var x=C.getContext('2d'); x.fillStyle='#ff0000'; x.fillRect(1,1,2,2);")
  assert_equal "255,0,0,255", MV::JS.eval("__mv_canvasGetPixel(C.__h,2,2).join(',')")
  assert_equal "0,0,0,0", MV::JS.eval("__mv_canvasGetPixel(C.__h,0,0).join(',')")
end

assert 'MV canvas clearRect resets pixels to transparent' do
  MV::JS.eval("C.getContext('2d').clearRect(0,0,4,4);")
  assert_equal "0,0,0,0", MV::JS.eval("__mv_canvasGetPixel(C.__h,2,2).join(',')")
end

assert 'MV canvas fillStyle accepts rgba() with alpha' do
  MV::JS.eval("var x=C.getContext('2d'); x.globalAlpha=1; x.fillStyle='rgba(0,0,255,1)'; x.fillRect(0,0,4,4);")
  assert_equal "0,0,255,255", MV::JS.eval("__mv_canvasGetPixel(C.__h,0,0).join(',')")
end

assert 'MV canvas globalAlpha blends fills (50% black over white -> gray)' do
  MV::JS.eval("globalThis.A=document.createElement('canvas'); A.width=2; A.height=2; var x=A.getContext('2d'); x.globalAlpha=1; x.fillStyle='#ffffff'; x.fillRect(0,0,2,2); x.fillStyle='#000000'; x.globalAlpha=0.5; x.fillRect(0,0,2,2);")
  assert_equal "127,127,127,255", MV::JS.eval("__mv_canvasGetPixel(A.__h,0,0).join(',')")
end

assert 'MV canvas drawImage copies a source canvas into a dest rect' do
  MV::JS.eval("globalThis.S=document.createElement('canvas'); S.width=2; S.height=2; var sx=S.getContext('2d'); sx.fillStyle='#00ff00'; sx.fillRect(0,0,2,2); globalThis.D=document.createElement('canvas'); D.width=4; D.height=4; D.getContext('2d').drawImage(S,1,1);")
  assert_equal "0,255,0,255", MV::JS.eval("__mv_canvasGetPixel(D.__h,1,1).join(',')")
  assert_equal "0,255,0,255", MV::JS.eval("__mv_canvasGetPixel(D.__h,2,2).join(',')")
  assert_equal "0,0,0,0", MV::JS.eval("__mv_canvasGetPixel(D.__h,0,0).join(',')")
end

assert 'MV canvas getImageData reads back a region' do
  MV::JS.eval("globalThis.G=document.createElement('canvas'); G.width=2; G.height=1; var x=G.getContext('2d'); x.fillStyle='#010203'; x.fillRect(0,0,2,1); globalThis.ID=x.getImageData(0,0,2,1);")
  assert_equal 8, MV::JS.eval("ID.data.length")
  assert_equal "1,2,3,255", MV::JS.eval("ID.data.slice(0,4).join(',')")
end

# A 2x2 RGBA PNG: pixel (0,0) is opaque red, the other three opaque green.
MV_IMAGE_PNG =
  "\x89\x50\x4e\x47\x0d\x0a\x1a\x0a\x00\x00\x00\x0d\x49\x48\x44\x52" \
  "\x00\x00\x00\x02\x00\x00\x00\x02\x08\x06\x00\x00\x00\x72\xb6\x0d" \
  "\x24\x00\x00\x00\x11\x49\x44\x41\x54\x78\xda\x63\xf8\xcf\xc0\xf0" \
  "\x1f\x0c\xa1\xd4\x7f\x00\x44\xcd\x07\xf9\x8c\x5e\x33\x5b\x00\x00" \
  "\x00\x00\x49\x45\x4e\x44\xae\x42\x60\x82"

assert 'MV Image decodes a PNG and serves as a drawImage source' do
  path = "mvjs_image_fixture.png"
  File.open(path, "wb") { |f| f.write(MV_IMAGE_PNG) }
  begin
    MV::JS.base_dir = ""
    # onload is async (browser-like): not fired until the host pumps a frame.
    # It fires from requestAnimationFrame, so a plain pump advances it (the
    # timestamp is irrelevant — kept small so the shared host clock is not
    # perturbed for later timer tests).
    MV::JS.eval("globalThis.IMG=new Image(); globalThis.IMG_ok=false; " \
                "IMG.onload=function(){IMG_ok=true;}; IMG.src='#{path}';")
    assert_equal false, MV::JS.eval("IMG_ok")
    MV::JS.pump(0.0)
    assert_equal true, MV::JS.eval("IMG_ok")
    assert_equal 2, MV::JS.eval("IMG.width")
    assert_equal 2, MV::JS.eval("IMG.height")
    # Draw the decoded image into a canvas and read pixels back.
    MV::JS.eval("globalThis.IC=document.createElement('canvas'); IC.width=2; " \
                "IC.height=2; IC.getContext('2d').drawImage(IMG,0,0);")
    assert_equal "255,0,0,255", MV::JS.eval("__mv_canvasGetPixel(IC.__h,0,0).join(',')")
    assert_equal "0,255,0,255", MV::JS.eval("__mv_canvasGetPixel(IC.__h,1,1).join(',')")
  ensure
    File.delete(path) rescue nil
  end
end

assert 'MV Image resolves a missing file as a 1x1 empty bitmap (boot does not stall)' do
  # A missing image loads (onload) as a 1x1 transparent bitmap rather than
  # erroring, so MV's ImageManager.isReady() does not block the boot forever on
  # reserved-but-absent system art (a project running without its art still
  # boots). onerror must NOT fire.
  MV::JS.base_dir = ""
  MV::JS.eval("globalThis.IE=new Image(); globalThis.IE_ok=false; globalThis.IE_err=false; " \
              "IE.onload=function(){IE_ok=true;}; IE.onerror=function(){IE_err=true;}; " \
              "IE.src='definitely_missing_image.png';")
  MV::JS.pump(0.0)
  assert_equal true, MV::JS.eval("IE_ok")
  assert_equal false, MV::JS.eval("IE_err")
  assert_equal 1, MV::JS.eval("IE.width")
  assert_equal 1, MV::JS.eval("IE.height")
  assert_equal true, MV::JS.eval("IE.complete")
end

assert 'MV::JS.present blits a canvas onto an RGSS::Bitmap with correct channels' do
  # Source canvas: opaque red at (0,0), opaque blue at (1,1). The RGBA canvas
  # and the ARGB8888 bitmap store channels in a different order, so this also
  # checks the R/B swap is right (red must read back as red, not blue).
  h = MV::JS.eval("globalThis.PC=document.createElement('canvas'); PC.width=2; " \
                  "PC.height=2; var x=PC.getContext('2d'); x.fillStyle='#ff0000'; " \
                  "x.fillRect(0,0,1,1); x.fillStyle='#0000ff'; x.fillRect(1,1,1,1); PC.__h")
  bmp = RGSS::Bitmap.new(2, 2)
  assert_equal true, MV::JS.present(bmp, h)
  red = bmp.get_pixel(0, 0)
  assert_equal 255.0, red.red
  assert_equal 0.0, red.green
  assert_equal 0.0, red.blue
  assert_equal 255.0, red.alpha
  blue = bmp.get_pixel(1, 1)
  assert_equal 0.0, blue.red
  assert_equal 255.0, blue.blue
end

assert 'MV::JS.present returns false for a bad handle or non-Bitmap' do
  bmp = RGSS::Bitmap.new(2, 2)
  assert_equal false, MV::JS.present(bmp, 0)          # handle 0 -> no canvas
  assert_equal false, MV::JS.present("not a bitmap", 1)
end

assert 'MV canvas translate offsets a drawImage blit' do
  MV::JS.eval("globalThis.TS=document.createElement('canvas'); TS.width=1; TS.height=1; " \
              "var s=TS.getContext('2d'); s.fillStyle='#ff0000'; s.fillRect(0,0,1,1);")
  MV::JS.eval("globalThis.TD=document.createElement('canvas'); TD.width=4; TD.height=4; " \
              "var x=TD.getContext('2d'); x.translate(2,1); x.drawImage(TS,0,0);")
  assert_equal "255,0,0,255", MV::JS.eval("__mv_canvasGetPixel(TD.__h,2,1).join(',')")
  assert_equal "0,0,0,0", MV::JS.eval("__mv_canvasGetPixel(TD.__h,0,0).join(',')")
end

assert 'MV canvas scale enlarges a drawImage blit' do
  MV::JS.eval("globalThis.SS=document.createElement('canvas'); SS.width=1; SS.height=1; " \
              "var s=SS.getContext('2d'); s.fillStyle='#00ff00'; s.fillRect(0,0,1,1);")
  MV::JS.eval("globalThis.SD=document.createElement('canvas'); SD.width=4; SD.height=4; " \
              "var x=SD.getContext('2d'); x.scale(2,2); x.drawImage(SS,0,0);")
  # The 1x1 source scaled 2x covers device pixels (0,0)..(1,1) but not (2,2).
  assert_equal "0,255,0,255", MV::JS.eval("__mv_canvasGetPixel(SD.__h,0,0).join(',')")
  assert_equal "0,255,0,255", MV::JS.eval("__mv_canvasGetPixel(SD.__h,1,1).join(',')")
  assert_equal "0,0,0,0", MV::JS.eval("__mv_canvasGetPixel(SD.__h,2,2).join(',')")
end

assert 'MV canvas translate offsets a fillRect' do
  MV::JS.eval("globalThis.FR=document.createElement('canvas'); FR.width=4; FR.height=4; " \
              "var x=FR.getContext('2d'); x.translate(1,1); x.fillStyle='#0000ff'; x.fillRect(0,0,2,2);")
  assert_equal "0,0,255,255", MV::JS.eval("__mv_canvasGetPixel(FR.__h,1,1).join(',')")
  assert_equal "0,0,0,0", MV::JS.eval("__mv_canvasGetPixel(FR.__h,0,0).join(',')")
end

assert 'MV document head/style shims support the font-loader boot path' do
  # Graphics._createFontLoader does getElementsByTagName('head')[0].appendChild(
  # style) then style.sheet.insertRule(...); both must exist so boot survives.
  assert_equal 1, MV::JS.eval("document.getElementsByTagName('head').length")
  ok = MV::JS.eval("var s=document.createElement('style'); " \
                   "document.getElementsByTagName('head')[0].appendChild(s); " \
                   "s.sheet.insertRule('.x{}', 0); 'ok'")
  assert_equal "ok", ok
  # Graphics._disableContextMenu walks document.body.getElementsByTagName('*').
  assert_equal 0, MV::JS.eval("document.body.getElementsByTagName('*').length")
  # Utils.canReadGameFiles reads the last <script>'s src over XHR; expose one.
  assert_equal true, MV::JS.eval("document.getElementsByTagName('script').length >= 1")
  assert_equal "string", MV::JS.eval("typeof document.getElementsByTagName('script')[0].src")
  # Scene_Boot advances only once the game font reports loaded; the CSS
  # font-loading path (document.fonts) must report ready/check==true.
  assert_equal true, MV::JS.eval("!!(document.fonts && document.fonts.ready)")
  assert_equal true, MV::JS.eval("document.fonts.check('10px GameFont')")
end

assert 'MV canvas gradient factories return chainable objects (gradientFillRect)' do
  assert_equal "function", MV::JS.eval(
    "typeof document.createElement('canvas').getContext('2d')" \
    ".createLinearGradient(0,0,1,1).addColorStop"
  )
  # The full Bitmap.gradientFillRect shape must not throw.
  assert_nil MV::JS.eval(
    "var x=document.createElement('canvas'); x.width=2; x.height=2; " \
    "var c=x.getContext('2d'); var g=c.createLinearGradient(0,0,2,0); " \
    "g.addColorStop(0,'#fff'); g.addColorStop(1,'#000'); c.fillStyle=g; " \
    "c.fillRect(0,0,2,2); null"
  )
end

assert 'MV canvas text API is wired (fillText/strokeText/measureText)' do
  # measureText must return a numeric width; empty text is zero in both the
  # font-backed and the no-font fallback path, so this holds regardless of
  # whether a game font is present in the test environment.
  assert_equal "number", MV::JS.eval(
    "typeof document.createElement('canvas').getContext('2d')" \
    ".measureText('hi').width"
  )
  assert_equal 0, MV::JS.eval(
    "document.createElement('canvas').getContext('2d').measureText('').width"
  )
  # fill/strokeText are real functions (no longer no-ops) and must not throw for
  # the full call shape MV uses, even when no font is loaded (they draw nothing).
  assert_equal "function", MV::JS.eval(
    "typeof document.createElement('canvas').getContext('2d').fillText"
  )
  assert_nil MV::JS.eval(
    "var x=document.createElement('canvas'); x.width=8; x.height=8; " \
    "var c=x.getContext('2d'); c.font='10px GameFont'; c.textAlign='center'; " \
    "c.textBaseline='alphabetic'; c.fillStyle='#ffffff'; " \
    "c.strokeStyle='rgba(0,0,0,0.5)'; c.lineWidth=4; " \
    "c.strokeText('Hi', 4, 6, 8); c.fillText('Hi', 4, 6, 8); null"
  )
end

assert 'MV canvas save/restore round-trips the transform' do
  m = MV::JS.eval("var x=document.createElement('canvas').getContext('2d'); " \
                  "x.save(); x.translate(5,7); x.scale(2,2); x.restore(); x._m.join(',')")
  assert_equal "1,0,0,1,0,0", m
end
