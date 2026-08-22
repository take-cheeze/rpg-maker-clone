# Tests for the Canvas2D -> RGBA-buffer bridge (milestone M4): document,
# HTMLCanvasElement and the 2D context that PIXI's canvas renderer targets.
# Pixels are read back with __mv_canvasGetPixel (joined to a scalar string so
# MV::JS.eval can return it).

assert 'MV document.createElement("canvas") yields a 2D context; other tags are inert' do
  assert_equal true, MV::JS.eval("!!document.createElement('canvas').getContext('2d')")
  # getContext('webgl') is covered in gl_test.rb (it depends on the native
  # EGL/GLES2 backend being compiled in; see MV::GL.available?). 'webgl2' stays
  # null regardless — MZ's PIXI v5 is WebGL1.
  assert_nil MV::JS.eval("document.createElement('canvas').getContext('webgl2')")
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

assert 'MV canvas putImageData writes pixels straight back (getImageData inverse)' do
  MV::JS.eval("globalThis.PD=document.createElement('canvas'); PD.width=2; PD.height=2; " \
              "var x=PD.getContext('2d'); x.fillStyle='#00ff00'; x.fillRect(0,0,2,2); " \
              "var d=x.getImageData(0,0,2,2); " \
              "for (var i=0;i<d.data.length;i+=4){d.data[i]=10;d.data[i+1]=20;d.data[i+2]=30;d.data[i+3]=255;} " \
              "x.putImageData(d,0,0);")
  assert_equal "10,20,30,255", MV::JS.eval("__mv_canvasGetPixel(PD.__h,0,0).join(',')")
  assert_equal "10,20,30,255", MV::JS.eval("__mv_canvasGetPixel(PD.__h,1,1).join(',')")
end

assert 'MV canvas putImageData clamps out-of-range channels (adjustTone add)' do
  # Bitmap.adjustTone does pixels[i] += tone against a plain array, so channels
  # can exceed 255 / go below 0; putImageData must clamp like a real ImageData's
  # Uint8ClampedArray. 0x80(128)+200 -> 255, 128-200 -> 0, blue left at 128.
  MV::JS.eval("var x=PD.getContext('2d'); x.fillStyle='#808080'; x.fillRect(0,0,2,2); " \
              "var d=x.getImageData(0,0,2,2); " \
              "for (var i=0;i<d.data.length;i+=4){d.data[i]+=200; d.data[i+1]-=200;} " \
              "x.putImageData(d,0,0);")
  assert_equal "255,0,128,255", MV::JS.eval("__mv_canvasGetPixel(PD.__h,0,0).join(',')")
end

assert 'MV canvas putImageData ignores the current transform (device coords)' do
  MV::JS.eval("globalThis.PT=document.createElement('canvas'); PT.width=2; PT.height=2; " \
              "var x=PT.getContext('2d'); x.translate(5,5); " \
              "x.putImageData({width:1,height:1,data:[7,8,9,255]},0,0);")
  assert_equal "7,8,9,255", MV::JS.eval("__mv_canvasGetPixel(PT.__h,0,0).join(',')")
end

assert "MV canvas globalCompositeOperation 'difference' yields |dest - source|" do
  # White base, then 'difference' with #404040 -> |255-64| = 191 per channel.
  MV::JS.eval("globalThis.DF=document.createElement('canvas'); DF.width=2; DF.height=2; " \
              "var x=DF.getContext('2d'); x.fillStyle='#ffffff'; x.fillRect(0,0,2,2); " \
              "x.globalCompositeOperation='difference'; x.fillStyle='#404040'; x.fillRect(0,0,2,2);")
  assert_equal "191,191,191,255", MV::JS.eval("__mv_canvasGetPixel(DF.__h,0,0).join(',')")
end

assert "MV canvas 'difference' white-on-white reads black (blend-mode probe)" do
  # Graphics._testCanvasBlendModes fills white, then 'difference' white and reads
  # the pixel: 0 means canUseDifferenceBlend, which negative screen tones need.
  MV::JS.eval("globalThis.DP=document.createElement('canvas'); DP.width=1; DP.height=1; " \
              "var x=DP.getContext('2d'); x.globalCompositeOperation='source-over'; " \
              "x.fillStyle='white'; x.fillRect(0,0,1,1); " \
              "x.globalCompositeOperation='difference'; x.fillStyle='white'; x.fillRect(0,0,1,1);")
  assert_equal "0,0,0,255", MV::JS.eval("__mv_canvasGetPixel(DP.__h,0,0).join(',')")
end

assert 'MV canvas negative-tone sequence darkens (difference/lighter/difference)' do
  # ToneSprite's negative-tone path: a -64 tone on a mid-grey frame -> invert,
  # add 64, invert -> frame darkened by 64 (128 -> 64).
  MV::JS.eval("globalThis.TN=document.createElement('canvas'); TN.width=2; TN.height=2; " \
              "var x=TN.getContext('2d'); x.fillStyle='#808080'; x.fillRect(0,0,2,2); " \
              "x.globalCompositeOperation='difference'; x.fillStyle='#ffffff'; x.fillRect(0,0,2,2); " \
              "x.globalCompositeOperation='lighter'; x.fillStyle='#404040'; x.fillRect(0,0,2,2); " \
              "x.globalCompositeOperation='difference'; x.fillStyle='#ffffff'; x.fillRect(0,0,2,2);")
  assert_equal "64,64,64,255", MV::JS.eval("__mv_canvasGetPixel(TN.__h,0,0).join(',')")
end

assert "MV canvas 'saturation' white fill desaturates to luminosity (grey tone)" do
  # A red frame fully desaturated -> grey at red's luminosity (0.30*255 ~= 76).
  MV::JS.eval("globalThis.ST=document.createElement('canvas'); ST.width=2; ST.height=2; " \
              "var x=ST.getContext('2d'); x.globalAlpha=1; x.fillStyle='#ff0000'; x.fillRect(0,0,2,2); " \
              "x.globalCompositeOperation='saturation'; x.fillStyle='#ffffff'; x.fillRect(0,0,2,2);")
  assert_equal "76,76,76,255", MV::JS.eval("__mv_canvasGetPixel(ST.__h,0,0).join(',')")
end

assert "MV canvas 'saturation' white-on-black reads black (blend-mode probe)" do
  # Graphics._testCanvasBlendModes: black, then 'saturation' white; pixel 0 sets
  # canUseSaturationBlend, which the grey-tone path needs.
  MV::JS.eval("globalThis.SP=document.createElement('canvas'); SP.width=1; SP.height=1; " \
              "var x=SP.getContext('2d'); x.fillStyle='#000000'; x.fillRect(0,0,1,1); " \
              "x.globalCompositeOperation='saturation'; x.fillStyle='#ffffff'; x.fillRect(0,0,1,1);")
  assert_equal "0,0,0,255", MV::JS.eval("__mv_canvasGetPixel(SP.__h,0,0).join(',')")
end

assert "MV canvas 'saturation' respects globalAlpha (partial desaturation)" do
  # Halfway from red (255,0,0) toward luminosity 76 -> (166,38,38).
  MV::JS.eval("globalThis.SG=document.createElement('canvas'); SG.width=2; SG.height=2; " \
              "var x=SG.getContext('2d'); x.globalAlpha=1; x.fillStyle='#ff0000'; x.fillRect(0,0,2,2); " \
              "x.globalCompositeOperation='saturation'; x.globalAlpha=0.5; x.fillStyle='#ffffff'; x.fillRect(0,0,2,2);")
  assert_equal "166,38,38,255", MV::JS.eval("__mv_canvasGetPixel(SG.__h,0,0).join(',')")
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

assert 'MV Image loads a percent-encoded filename (encodeURIComponent path)' do
  # MV builds asset URLs with encodeURIComponent(filename), so a "$Hero"
  # character sheet is requested as "%24Hero.png". The loader must url-decode to
  # find the on-disk file; without it the load falls back to a 1x1 empty bitmap.
  # The file on disk carries the literal "$"; we request it percent-encoded.
  disk = "mvjs_$enc_fixture.png"
  File.open(disk, "wb") { |f| f.write(MV_IMAGE_PNG) }
  begin
    MV::JS.base_dir = ""
    MV::JS.eval("globalThis.ENC=new Image(); ENC.src='mvjs_%24enc_fixture.png';")
    MV::JS.pump(0.0)
    # width == 2 proves the real 2x2 file was found (a decode miss would be 1x1).
    assert_equal 2, MV::JS.eval("ENC.width")
    assert_equal 2, MV::JS.eval("ENC.height")
  ensure
    File.delete(disk) rescue nil
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

assert 'MV canvas createPattern tiles a source across fillRect (repeat)' do
  # 2x2 source: red, green / blue, white. MV's TilingSprite (parallax,
  # battlebacks) fills with such a pattern; the tile must repeat as (x%2, y%2).
  MV::JS.eval("globalThis.PS=document.createElement('canvas'); PS.width=2; PS.height=2; " \
              "var s=PS.getContext('2d'); " \
              "s.fillStyle='#ff0000'; s.fillRect(0,0,1,1); s.fillStyle='#00ff00'; s.fillRect(1,0,1,1); " \
              "s.fillStyle='#0000ff'; s.fillRect(0,1,1,1); s.fillStyle='#ffffff'; s.fillRect(1,1,1,1); " \
              "globalThis.PDST=document.createElement('canvas'); PDST.width=4; PDST.height=4; " \
              "var x=PDST.getContext('2d'); x.fillStyle=x.createPattern(PS,'repeat'); x.fillRect(0,0,4,4);")
  assert_equal "255,0,0,255", MV::JS.eval("__mv_canvasGetPixel(PDST.__h,0,0).join(',')")     # src(0,0)
  assert_equal "0,255,0,255", MV::JS.eval("__mv_canvasGetPixel(PDST.__h,1,0).join(',')")     # src(1,0)
  assert_equal "255,0,0,255", MV::JS.eval("__mv_canvasGetPixel(PDST.__h,2,0).join(',')")     # wrap -> src(0,0)
  assert_equal "0,0,255,255", MV::JS.eval("__mv_canvasGetPixel(PDST.__h,0,1).join(',')")     # src(0,1)
  assert_equal "255,255,255,255", MV::JS.eval("__mv_canvasGetPixel(PDST.__h,3,3).join(',')") # src(1,1)
end

assert 'MV canvas pattern fill honors the transform (translate anchors tiling)' do
  # createPattern tiles anchored at the user-space origin, so a translate shifts
  # which tile lands where; device(1,0) <- user(0,0)=red, device(0,0) <-
  # user(-1,0) which wraps to src(1,0)=green.
  MV::JS.eval("globalThis.PT2=document.createElement('canvas'); PT2.width=4; PT2.height=2; " \
              "var x=PT2.getContext('2d'); x.translate(1,0); " \
              "x.fillStyle=x.createPattern(PS,'repeat'); x.fillRect(-1,0,5,2);")
  assert_equal "0,255,0,255", MV::JS.eval("__mv_canvasGetPixel(PT2.__h,0,0).join(',')")   # wrapped green
  assert_equal "255,0,0,255", MV::JS.eval("__mv_canvasGetPixel(PT2.__h,1,0).join(',')")   # red
end

assert 'MV canvas path fill rasterises a polygon (beginPath/lineTo/fill)' do
  # A filled triangle (0,0)-(0,4)-(4,4) covering the lower-left half of a 4x4.
  MV::JS.eval("globalThis.PG=document.createElement('canvas'); PG.width=4; PG.height=4; " \
              "var x=PG.getContext('2d'); x.fillStyle='#00ff00'; " \
              "x.beginPath(); x.moveTo(0,0); x.lineTo(0,4); x.lineTo(4,4); x.closePath(); x.fill();")
  assert_equal "0,255,0,255", MV::JS.eval("__mv_canvasGetPixel(PG.__h,1,3).join(',')") # inside
  assert_equal "0,0,0,0", MV::JS.eval("__mv_canvasGetPixel(PG.__h,3,0).join(',')")     # outside
end

assert 'MV canvas fills a circle (arc + fill, e.g. Bitmap.drawCircle / snow)' do
  # Bitmap.drawCircle(4,4,4,'white') on a 9x9 bitmap — how Weather draws snow.
  MV::JS.eval("globalThis.CI=document.createElement('canvas'); CI.width=9; CI.height=9; " \
              "var x=CI.getContext('2d'); x.fillStyle='#ffffff'; " \
              "x.beginPath(); x.arc(4,4,4,0,Math.PI*2); x.fill();")
  assert_equal "255,255,255,255", MV::JS.eval("__mv_canvasGetPixel(CI.__h,4,4).join(',')") # centre
  assert_equal "0,0,0,0", MV::JS.eval("__mv_canvasGetPixel(CI.__h,0,0).join(',')")         # corner, outside r
end

assert 'MV canvas path fill honors the transform' do
  # translate shifts the whole polygon: the triangle at user (0,0)-(0,2)-(2,2)
  # drawn with translate(1,1) fills around device (1,1)..(3,3).
  MV::JS.eval("globalThis.PGT=document.createElement('canvas'); PGT.width=4; PGT.height=4; " \
              "var x=PGT.getContext('2d'); x.translate(1,1); x.fillStyle='#0000ff'; " \
              "x.beginPath(); x.moveTo(0,0); x.lineTo(0,2); x.lineTo(2,2); x.fill();")
  assert_equal "0,0,255,255", MV::JS.eval("__mv_canvasGetPixel(PGT.__h,1,2).join(',')") # inside, shifted
  assert_equal "0,0,0,0", MV::JS.eval("__mv_canvasGetPixel(PGT.__h,0,0).join(',')")     # origin, untouched
end

assert 'MV canvas stroke draws a lineWidth-thick line along a segment' do
  # A horizontal stroke of width 2 centred on y=2 fills the band y in [1,3).
  MV::JS.eval("globalThis.SK=document.createElement('canvas'); SK.width=4; SK.height=4; " \
              "var x=SK.getContext('2d'); x.strokeStyle='#ff0000'; x.lineWidth=2; " \
              "x.beginPath(); x.moveTo(0,2); x.lineTo(4,2); x.stroke();")
  assert_equal "255,0,0,255", MV::JS.eval("__mv_canvasGetPixel(SK.__h,2,1).join(',')") # on the band
  assert_equal "0,0,0,0", MV::JS.eval("__mv_canvasGetPixel(SK.__h,2,3).join(',')")     # below the band
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

assert "MV canvas globalCompositeOperation 'lighter' adds fills (additive blend)" do
  # MV sets ctx.globalCompositeOperation='lighter' for battle-animation flashes,
  # weather and glow sprites. The second fill must add to the first, not replace
  # it: 0x30+0x10 red, 0x00+0x10 green/blue; alpha stays opaque.
  MV::JS.eval("globalThis.L=document.createElement('canvas'); L.width=2; L.height=2; " \
              "var x=L.getContext('2d'); x.globalAlpha=1; " \
              "x.globalCompositeOperation='source-over'; x.fillStyle='#300000'; x.fillRect(0,0,2,2); " \
              "x.globalCompositeOperation='lighter'; x.fillStyle='#101010'; x.fillRect(0,0,2,2);")
  assert_equal "64,16,16,255", MV::JS.eval("__mv_canvasGetPixel(L.__h,0,0).join(',')")
end

assert "MV canvas 'lighter' clamps additive fills at 255" do
  MV::JS.eval("var x=L.getContext('2d'); x.globalCompositeOperation='source-over'; " \
              "x.fillStyle='#f0f0f0'; x.fillRect(0,0,2,2); " \
              "x.globalCompositeOperation='lighter'; x.fillStyle='#303030'; x.fillRect(0,0,2,2);")
  assert_equal "255,255,255,255", MV::JS.eval("__mv_canvasGetPixel(L.__h,0,0).join(',')")
end

assert "MV canvas 'lighter' drawImage adds the source over the dest" do
  # An opaque green source additively drawn over an opaque red dest -> yellow.
  MV::JS.eval("globalThis.LS=document.createElement('canvas'); LS.width=2; LS.height=2; " \
              "var s=LS.getContext('2d'); s.fillStyle='#00ff00'; s.fillRect(0,0,2,2); " \
              "globalThis.LD=document.createElement('canvas'); LD.width=2; LD.height=2; " \
              "var d=LD.getContext('2d'); d.fillStyle='#ff0000'; d.fillRect(0,0,2,2); " \
              "d.globalCompositeOperation='lighter'; d.drawImage(LS,0,0);")
  assert_equal "255,255,0,255", MV::JS.eval("__mv_canvasGetPixel(LD.__h,0,0).join(',')")
end

assert 'MV canvas default composite still overwrites on drawImage (source-over)' do
  # Regression: with no 'lighter' the blit replaces rather than adds.
  MV::JS.eval("var d=LD.getContext('2d'); d.globalCompositeOperation='source-over'; " \
              "d.fillStyle='#ff0000'; d.fillRect(0,0,2,2); " \
              "globalThis.LS2=document.createElement('canvas'); LS2.width=2; LS2.height=2; " \
              "var s=LS2.getContext('2d'); s.fillStyle='#00ff00'; s.fillRect(0,0,2,2); " \
              "d.drawImage(LS2,0,0);")
  assert_equal "0,255,0,255", MV::JS.eval("__mv_canvasGetPixel(LD.__h,0,0).join(',')")
end

assert 'MV canvas save/restore round-trips globalCompositeOperation' do
  v = MV::JS.eval("var x=document.createElement('canvas').getContext('2d'); " \
                  "x.save(); x.globalCompositeOperation='lighter'; x.restore(); " \
                  "x.globalCompositeOperation")
  assert_equal "source-over", v
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
  # document.body.getBoundingClientRect() used to always report a 0x0 rect --
  # a real browser's reports the actual viewport, and some MV/MZ corescript
  # builds read a game's initial screen resolution from this rect (instead of,
  # or alongside, window.innerWidth/innerHeight). An all-zero stand-in fed
  # those a 0x0 resolution silently. Now matches window.innerWidth/innerHeight.
  assert_equal true, MV::JS.eval(
    "var r = document.body.getBoundingClientRect(); " \
    "r.width === window.innerWidth && r.height === window.innerHeight && " \
    "r.width > 0 && r.height > 0"
  )
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

assert 'MV canvas measureText: a font shorthand without "GameFont" always uses '\
      'the rough per-character estimate' do
  # Regression: a bare font-agnostic measureText (the pre-fix behavior) can't
  # tell '28px GameFont, sans-serif' from '28px sans-serif' apart, so
  # Graphics.isFontLoaded('GameFont') -- which measures exactly that pair and
  # waits for the widths to diverge -- never sees them differ and hangs
  # Scene_Boot on any MV project whose corescript uses that classic detection
  # (rather than the newer FontFaceSet path our document.fonts stand-in
  # already covers). A real game (extracted from an Enigma Virtual Box-packed
  # RPG Maker MV release) hit exactly this: stuck at Scene_Boot until its own
  # 20s timeout, `Error: Failed to load GameFont`.
  #
  # Fixed by having measureText route a font shorthand that doesn't name
  # "GameFont" through the same rough text.length*pixel*0.5 estimate used when
  # no game font is loaded at all, guaranteeing it differs from the real
  # metrics measured against an actual loaded font -- asserted here by its
  # exact value, so this holds whether or not this test environment happens to
  # have a real font loaded.
  assert_equal 100.0, MV::JS.eval(
    "var c=document.createElement('canvas').getContext('2d'); " \
    "c.font='40px sans-serif'; c.measureText('abcde').width"
  )
  assert_equal 40.0, MV::JS.eval(
    "var c=document.createElement('canvas').getContext('2d'); " \
    "c.font='40px serif'; c.measureText('ab').width"
  )
end

assert 'MV canvas gradientFillRect interpolates colours across the rect' do
  # A horizontal red -> blue gradient over a 4px-wide rect (as MV's
  # Bitmap.gradientFillRect drives for gauges). The left edge should be
  # red-dominant and opaque, the right edge blue-dominant.
  MV::JS.eval(
    "globalThis.GR=document.createElement('canvas'); GR.width=4; GR.height=1; " \
    "var c=GR.getContext('2d'); var g=c.createLinearGradient(0,0,4,0); " \
    "g.addColorStop(0,'#ff0000'); g.addColorStop(1,'#0000ff'); " \
    "c.fillStyle=g; c.fillRect(0,0,4,1);"
  )
  assert_equal true, MV::JS.eval("var p=__mv_canvasGetPixel(GR.__h,0,0); p[0] > p[2]")
  assert_equal 255, MV::JS.eval("__mv_canvasGetPixel(GR.__h,0,0)[3]")
  assert_equal true, MV::JS.eval("var p=__mv_canvasGetPixel(GR.__h,3,0); p[2] > p[0]")
  # A gradient fillStyle no longer reads back as opaque black (the old fallback).
  assert_equal false, MV::JS.eval("__mv_canvasGetPixel(GR.__h,0,0).slice(0,3).join(',') === '0,0,0'")
end

assert 'MV canvas save/restore round-trips the transform' do
  m = MV::JS.eval("var x=document.createElement('canvas').getContext('2d'); " \
                  "x.save(); x.translate(5,7); x.scale(2,2); x.restore(); x._m.join(',')")
  assert_equal "1,0,0,1,0,0", m
end

assert 'MV canvas strokeRect outlines a rect without filling it' do
  # MZ's Window_Selectable.drawBackgroundRect strokes the frame of every item in
  # every selectable window (Bitmap.strokeRect -> context.strokeRect), so a
  # context without this method throws "not a function" the first time a command
  # window is built and the boot dies at Scene_Title. Check the outline lands on
  # the border and leaves the interior alone.
  MV::JS.eval(
    "globalThis.SR=document.createElement('canvas'); SR.width=6; SR.height=6; " \
    "var c=SR.getContext('2d'); c.strokeStyle='#00ff00'; c.lineWidth=1; " \
    "c.strokeRect(1,1,4,4);"
  )
  # All four edges are stroked: the box spans x/y 1..5 (the rect's own border,
  # since a 1px line centred on the path rounds onto it).
  assert_equal "0,255,0,255", MV::JS.eval("__mv_canvasGetPixel(SR.__h,2,1).join(',')")
  assert_equal "0,255,0,255", MV::JS.eval("__mv_canvasGetPixel(SR.__h,2,5).join(',')")
  assert_equal "0,255,0,255", MV::JS.eval("__mv_canvasGetPixel(SR.__h,1,3).join(',')")
  assert_equal "0,255,0,255", MV::JS.eval("__mv_canvasGetPixel(SR.__h,5,3).join(',')")
  # ...and the middle is untouched: a stroke is not a fill.
  assert_equal "0,0,0,0", MV::JS.eval("__mv_canvasGetPixel(SR.__h,3,3).join(',')")
  # strokeRect must not leak the stroke colour into fillStyle for later draws.
  assert_equal "#000000", MV::JS.eval("SR.getContext('2d').fillStyle")
end
