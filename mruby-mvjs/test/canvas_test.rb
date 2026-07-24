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
