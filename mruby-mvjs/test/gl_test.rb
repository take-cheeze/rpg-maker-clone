# Tests the EGL GLES2 backend that will host the MZ WebGL renderer
# (milestone M6.3a). Unlike the MZ engine specs, this drives the native GL
# pipeline directly through MV::GL, so it runs in CI on headless runners with no
# proprietary MZ project — it is the CI proof that the backend works.

assert 'MV::GL.smoke_test renders a green triangle through EGL GLES2' do
  # The EGL backend is optional: absent on Emscripten (browser WebGL) and
  # where the EGL headers were missing at build time (e.g. darwin). Skip
  # cleanly there; the backend is exercised wherever EGL is present — the
  # apt-based dev build and the nix build (surfaceless EGL over llvmpipe), so
  # this runs in CI.
  skip 'EGL/GLES2 backend not compiled into this build' unless MV::GL.available?

  px = MV::GL.smoke_test
  # nil means the EGL context or the GLSL ES 1.00 shader path failed; the
  # [MZ-GL] stderr line above says which. On success px is the rendered centre
  # pixel [r, g, b, a], and the full-viewport triangle is solid green.
  assert_false px.nil?
  if px
    assert_equal 4, px.size
    assert_true px[1] > 200  # green channel high
    assert_true px[0] < 60   # red channel low
    assert_true px[2] < 60   # blue channel low
  end
end

# --- M6.3b: the WebGL wrapper (getContext('webgl') -> the native backend) -----

assert 'canvas.getContext("webgl") returns a WebGLRenderingContext with the WebGL surface' do
  # Backed by the same native EGL/GLES2 context as MV::GL, so it is only present
  # where that compiled in — skip cleanly otherwise (matching the smoke above).
  skip 'EGL/GLES2 backend not compiled into this build' unless MV::GL.available?

  # Non-null for 'webgl' and the legacy 'experimental-webgl' alias Utils probes.
  assert_equal true, MV::JS.eval("!!document.createElement('canvas').getContext('webgl')")
  assert_equal true, MV::JS.eval("!!document.createElement('canvas').getContext('experimental-webgl')")
  # Same object is returned on repeat calls (PIXI caches the context).
  assert_equal true, MV::JS.eval(
    "var c=document.createElement('canvas'); c.getContext('webgl')===c.getContext('webgl')")

  # Reuse one context (a fresh EGL context per assert would be wasteful).
  MV::JS.eval("globalThis.GL = document.createElement('canvas').getContext('webgl');")
  # The methods Utils.canUseWebGL / PIXI's renderer construction touch exist.
  %w[createShader shaderSource compileShader createProgram linkProgram useProgram
     createBuffer bindBuffer bufferData vertexAttribPointer getParameter
     getExtension getContextAttributes drawArrays readPixels createTexture
     texImage2D getActiveUniform].each do |m|
    assert_equal 'function', MV::JS.eval("typeof GL.#{m}")
  end
  # getParameter returns a usable version string and integer limits (not undefined).
  assert_equal 'string', MV::JS.eval("typeof GL.getParameter(GL.VERSION)")
  assert_true MV::JS.eval("GL.getParameter(GL.MAX_TEXTURE_SIZE)") >= 64
end

assert 'the Utils.canUseWebGL() gate shape passes through the wrapper' do
  skip 'EGL/GLES2 backend not compiled into this build' unless MV::GL.available?

  # Replicate rmmz Utils.canUseWebGL: create a canvas, get a webgl context (with
  # the experimental alias fallback), and require a non-null context. rmmz's own
  # source is absent from CI, so the gate's shape is reproduced inline.
  assert_equal true, MV::JS.eval(<<~'JS')
    (function () {
      try {
        var c = document.createElement('canvas');
        var gl = c.getContext('webgl') || c.getContext('experimental-webgl');
        return !!gl;
      } catch (e) { return false; }
    })()
  JS
end

# --- M6.3c: gaps PIXI v5 exercises at renderer construction -------------------

assert 'WebGLRenderingContext exposes the GL enums as constructor statics (PIXI reads them there)' do
  skip 'EGL/GLES2 backend not compiled into this build' unless MV::GL.available?

  # PIXI v5's ScissorSystem/StencilSystem read the enum off the *constructor*
  # (e.g. `WebGLRenderingContext.SCISSOR_TEST`) while building the renderer, not
  # off the context instance — so `new PIXI.Renderer` throws a ReferenceError
  # without these statics. (Found by booting PIXI v5.2.4 against the wrapper's
  # method surface.) Values are the standard WebGL/GLES2 tokens.
  assert_equal 0x0C11, MV::JS.eval("WebGLRenderingContext.SCISSOR_TEST")  # 3089
  assert_equal 0x0B90, MV::JS.eval("WebGLRenderingContext.STENCIL_TEST")  # 2960
  assert_equal 0x1908, MV::JS.eval("WebGLRenderingContext.RGBA")          # 6408
  assert_equal 0x0DE1, MV::JS.eval("WebGLRenderingContext.TEXTURE_2D")    # 3553
  # The same enums remain on the instance (read as `gl.RGBA`).
  assert_equal 0x1908, MV::JS.eval("document.createElement('canvas').getContext('webgl').RGBA")
end

assert 'a green triangle renders end to end through the WebGL wrapper' do
  skip 'EGL/GLES2 backend not compiled into this build' unless MV::GL.available?

  # The JS-layer analog of MV::GL.smoke_test: drive the whole pipeline
  # (compile ES 1.00 shaders, buffer, draw, readPixels) through the
  # WebGLRenderingContext wrapper, proving it reaches the native GLES2 backend.
  # Returns the centre pixel's green channel (0..255), or a negative error code.
  g = MV::JS.eval(<<~'JS')
    (function () {
      var W = 64, H = 64;
      var cv = document.createElement('canvas'); cv.width = W; cv.height = H;
      var gl = cv.getContext('webgl');
      if (!gl) return -1;
      var vs = gl.createShader(gl.VERTEX_SHADER);
      gl.shaderSource(vs, '#version 100\nattribute vec2 aPos;\nvoid main(){ gl_Position = vec4(aPos,0.0,1.0); }\n');
      gl.compileShader(vs);
      if (!gl.getShaderParameter(vs, gl.COMPILE_STATUS)) { console.error(gl.getShaderInfoLog(vs)); return -2; }
      var fs = gl.createShader(gl.FRAGMENT_SHADER);
      gl.shaderSource(fs, '#version 100\nprecision mediump float;\nvoid main(){ gl_FragColor = vec4(0.0,1.0,0.0,1.0); }\n');
      gl.compileShader(fs);
      if (!gl.getShaderParameter(fs, gl.COMPILE_STATUS)) { console.error(gl.getShaderInfoLog(fs)); return -3; }
      var p = gl.createProgram();
      gl.attachShader(p, vs); gl.attachShader(p, fs);
      gl.bindAttribLocation(p, 0, 'aPos');
      gl.linkProgram(p);
      if (!gl.getProgramParameter(p, gl.LINK_STATUS)) { console.error(gl.getProgramInfoLog(p)); return -4; }
      gl.useProgram(p);
      gl.viewport(0, 0, W, H);
      gl.clearColor(0.2, 0.0, 0.0, 1.0);
      gl.clear(gl.COLOR_BUFFER_BIT);
      var buf = gl.createBuffer();
      gl.bindBuffer(gl.ARRAY_BUFFER, buf);
      gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1,-1, 3,-1, -1,3]), gl.STATIC_DRAW);
      gl.enableVertexAttribArray(0);
      gl.vertexAttribPointer(0, 2, gl.FLOAT, false, 0, 0);
      gl.drawArrays(gl.TRIANGLES, 0, 3);
      gl.finish();
      var px = new Uint8Array(4);
      gl.readPixels(W / 2, H / 2, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, px);
      return (px[0] < 60 && px[1] > 200 && px[2] < 60) ? px[1] : -(100 + px[1]);
    })()
  JS
  assert_true g > 200
end

# --- M6.3 present path: WebGL FBO -> on-screen RGSS::Bitmap ------------------

assert 'MV::JS.present_gl copies a rendered WebGL frame onto an RGSS::Bitmap' do
  skip 'EGL/GLES2 backend not compiled into this build' unless MV::GL.available?

  # Clear a WebGL canvas to opaque green, then present its FBO onto a Bitmap.
  # This is the native core of the MZ on-screen present (mz.rb copies PIXI's
  # rendered frame this way each frame). The FBO is RGBA and the Bitmap is
  # ARGB8888, so it also checks the R/B swap (green reads back as green) and that
  # the WebGL handle (`.__gl`) resolves.
  handle = MV::JS.eval(<<~'JS')
    (function () {
      var cv = document.createElement('canvas'); cv.width = 8; cv.height = 8;
      var gl = cv.getContext('webgl');
      if (!gl) return 0;
      gl.viewport(0, 0, 8, 8);
      gl.clearColor(0.0, 1.0, 0.0, 1.0);
      gl.clear(gl.COLOR_BUFFER_BIT);
      gl.finish();
      return gl.__gl;
    })()
  JS
  assert_true handle > 0

  bmp = RGSS::Bitmap.new(8, 8)
  assert_equal true, MV::JS.present_gl(bmp, handle)
  c = bmp.get_pixel(4, 4)
  assert_true c.green > 200 # green channel high
  assert_true c.red < 60    # red low
  assert_true c.blue < 60   # blue low
  assert_equal 255.0, c.alpha
end

assert 'MV::JS.present_gl returns false for a bad handle' do
  bmp = RGSS::Bitmap.new(2, 2)
  assert_equal false, MV::JS.present_gl(bmp, 0)
end

assert 'a WebGL context follows its canvas when the canvas is resized' do
  skip 'EGL/GLES2 backend not compiled into this build' unless MV::GL.available?

  # MZ's order, which the tests above did not cover: take the context *first*
  # (from a canvas that is still 0x0, so the native target is created at the
  # 1x1 minimum), and only then size the canvas — Scene_Boot.resizeScreen ->
  # Graphics.resize -> PIXI's renderer.resize assigns canvas.width/height. Before
  # the render target followed, the whole game rendered into that 1x1 buffer, so
  # the on-screen present and the screenshot both read back a single pixel.
  handle = MV::JS.eval(<<~'JS')
    (function () {
      var cv = document.createElement('canvas');
      globalThis.RCV = cv;
      var gl = cv.getContext('webgl');   // canvas still 0x0 here
      if (!gl) return 0;
      globalThis.RGL = gl;
      cv.width = 24; cv.height = 16;     // ... sized only afterwards
      return gl.__gl;
    })()
  JS
  assert_true handle > 0

  # The context reports the new size...
  assert_equal 24, MV::JS.eval("RGL.drawingBufferWidth")
  assert_equal 16, MV::JS.eval("RGL.drawingBufferHeight")

  # ...and the render target really is that big: clear it blue and read a pixel
  # back from a corner only the resized buffer has.
  MV::JS.eval(
    "RGL.viewport(0, 0, 24, 16); RGL.clearColor(0.0, 0.0, 1.0, 1.0); " \
    "RGL.clear(RGL.COLOR_BUFFER_BIT); RGL.finish();"
  )
  bmp = RGSS::Bitmap.new(24, 16)
  assert_equal true, MV::JS.present_gl(bmp, handle)
  c = bmp.get_pixel(20, 12) # outside a 1x1 target
  assert_true c.blue > 200
  assert_true c.red < 60
  assert_equal 255.0, c.alpha
end

assert 'the stencil test masks a draw, the way MZ clips its windows' do
  skip 'EGL/GLES2 backend not compiled into this build' unless MV::GL.available?

  # MZ's WindowLayer.render masks with the stencil buffer: each window is drawn
  # where the buffer is 0, then its own shape is stamped with REPLACE so the
  # window behind it cannot paint over it. The wrapper used to accept
  # stencilFunc/stencilOp/stencilMask and throw them away, so every window
  # overpainted its neighbours — the FBO's packed DEPTH24_STENCIL8 buffer was
  # there all along, just never programmed.
  #
  # Reproduce that shape at the pixel level: stamp the left half of the target,
  # then draw a full-screen quad that must only survive on the *right*. Returns
  # "left,right" green channels.
  out = MV::JS.eval(<<~'JS')
    (function () {
      var W = 64, H = 64;
      var cv = document.createElement('canvas'); cv.width = W; cv.height = H;
      var gl = cv.getContext('webgl');
      if (!gl) return 'no-context';
      function shader(type, src) {
        var s = gl.createShader(type);
        gl.shaderSource(s, src); gl.compileShader(s);
        return gl.getShaderParameter(s, gl.COMPILE_STATUS) ? s : null;
      }
      var vs = shader(gl.VERTEX_SHADER,
        '#version 100\nattribute vec2 aPos;\nvoid main(){ gl_Position = vec4(aPos,0.0,1.0); }\n');
      var fs = shader(gl.FRAGMENT_SHADER,
        '#version 100\nprecision mediump float;\nuniform vec4 uCol;\nvoid main(){ gl_FragColor = uCol; }\n');
      if (!vs || !fs) return 'shader-failed';
      var p = gl.createProgram();
      gl.attachShader(p, vs); gl.attachShader(p, fs);
      gl.bindAttribLocation(p, 0, 'aPos');
      gl.linkProgram(p);
      if (!gl.getProgramParameter(p, gl.LINK_STATUS)) return 'link-failed';
      gl.useProgram(p);
      var uCol = gl.getUniformLocation(p, 'uCol');
      gl.viewport(0, 0, W, H);

      var buf = gl.createBuffer();
      gl.bindBuffer(gl.ARRAY_BUFFER, buf);
      gl.enableVertexAttribArray(0);
      gl.vertexAttribPointer(0, 2, gl.FLOAT, false, 0, 0);
      function quad(x0, x1) {
        gl.bufferData(gl.ARRAY_BUFFER,
          new Float32Array([x0,-1, x1,-1, x0,1, x1,-1, x1,1, x0,1]), gl.STATIC_DRAW);
        gl.drawArrays(gl.TRIANGLES, 0, 6);
      }

      gl.clearColor(0.0, 0.0, 0.0, 1.0);
      gl.clearStencil(0);
      gl.clear(gl.COLOR_BUFFER_BIT | gl.STENCIL_BUFFER_BIT);
      gl.enable(gl.STENCIL_TEST);

      // Pass 1: stamp stencil = 1 over the left half (colour irrelevant).
      gl.stencilMask(0xff);
      gl.stencilFunc(gl.ALWAYS, 1, 0xff);
      gl.stencilOp(gl.KEEP, gl.KEEP, gl.REPLACE);
      gl.uniform4f(uCol, 0.0, 0.0, 0.0, 1.0);
      quad(-1.0, 0.0);

      // Pass 2: draw green everywhere, but only where the stencil is still 0.
      gl.stencilFunc(gl.EQUAL, 0, 0xff);
      gl.stencilOp(gl.KEEP, gl.KEEP, gl.KEEP);
      gl.uniform4f(uCol, 0.0, 1.0, 0.0, 1.0);
      quad(-1.0, 1.0);
      gl.finish();

      var l = new Uint8Array(4), r = new Uint8Array(4);
      gl.readPixels(W / 4, H / 2, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, l);      // left
      gl.readPixels(W * 3 / 4, H / 2, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, r);  // right
      gl.disable(gl.STENCIL_TEST);
      return l[1] + ',' + r[1];
    })()
  JS

  # Surface a setup failure as itself rather than as a confusing 0,0.
  assert_false ["no-context", "shader-failed", "link-failed"].include?(out)

  # The masked (left) half must have stayed black and the unmasked (right) half
  # must be green. With the old no-op stubs both halves came out green, since
  # nothing ever wrote or tested the buffer.
  parts = out.split(",")
  assert_equal 2, parts.size
  assert_true parts[1].to_i > 200 # right: drawn
  assert_true parts[0].to_i < 60  # left: masked out
end

assert 'bufferData accepts a bare ArrayBuffer, the way PIXI uploads a sprite batch' do
  skip 'EGL/GLES2 backend not compiled into this build' unless MV::GL.available?

  # WebGL's `BufferSource` is `ArrayBufferView | ArrayBuffer`, and PIXI v5's
  # sprite batcher uploads its whole interleaved vertex block as the raw
  # ArrayBuffer behind its views (`ViewableBuffer.rawBinaryData`). The wrapper
  # used to read bytes only out of a *view*, so that upload silently became
  # zero-length and every batched sprite drew from an empty vertex buffer —
  # degenerate triangles, no fragments. That is why MZ drew its tilemap (rmmz's
  # own renderer, with its own geometry) and nothing else: no characters, no
  # windows, no text.
  #
  # Reproduce it at the pixel level: write a full-viewport quad through a
  # Float32Array view but hand `bufferData` the *buffer*, then draw green.
  out = MV::JS.eval(<<~'JS')
    (function () {
      var W = 32, H = 32;
      var cv = document.createElement('canvas'); cv.width = W; cv.height = H;
      var gl = cv.getContext('webgl');
      if (!gl) return 'no-context';
      function shader(type, src) {
        var s = gl.createShader(type);
        gl.shaderSource(s, src); gl.compileShader(s);
        return gl.getShaderParameter(s, gl.COMPILE_STATUS) ? s : null;
      }
      var vs = shader(gl.VERTEX_SHADER,
        '#version 100\nattribute vec2 aPos;\nvoid main(){ gl_Position = vec4(aPos,0.0,1.0); }\n');
      var fs = shader(gl.FRAGMENT_SHADER,
        '#version 100\nprecision mediump float;\nvoid main(){ gl_FragColor = vec4(0.0,1.0,0.0,1.0); }\n');
      if (!vs || !fs) return 'shader-failed';
      var p = gl.createProgram();
      gl.attachShader(p, vs); gl.attachShader(p, fs);
      gl.bindAttribLocation(p, 0, 'aPos');
      gl.linkProgram(p);
      if (!gl.getProgramParameter(p, gl.LINK_STATUS)) return 'link-failed';
      gl.useProgram(p);
      gl.viewport(0, 0, W, H);
      gl.clearColor(0.0, 0.0, 0.0, 1.0);
      gl.clear(gl.COLOR_BUFFER_BIT);

      // The data is written through a view; the *buffer* is what is uploaded.
      var view = new Float32Array([-1,-1, 1,-1, -1,1, 1,-1, 1,1, -1,1]);
      var buf = gl.createBuffer();
      gl.bindBuffer(gl.ARRAY_BUFFER, buf);
      gl.bufferData(gl.ARRAY_BUFFER, view.buffer, gl.STATIC_DRAW);
      gl.enableVertexAttribArray(0);
      gl.vertexAttribPointer(0, 2, gl.FLOAT, false, 0, 0);
      gl.drawArrays(gl.TRIANGLES, 0, 6);
      gl.finish();

      var px = new Uint8Array(4);
      gl.readPixels(W / 2, H / 2, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, px);
      return px[0] + ',' + px[1] + ',' + px[2];
    })()
  JS

  assert_false ["no-context", "shader-failed", "link-failed"].include?(out)
  rgb = out.split(",").map { |v| v.to_i }
  assert_equal 3, rgb.size
  assert_true rgb[1] > 200 # green: the quad drew, so the buffer carried data
  assert_true rgb[0] < 60
end

assert 'texSubImage2D updates a texture after its first upload' do
  skip 'EGL/GLES2 backend not compiled into this build' unless MV::GL.available?

  # PIXI re-uploads a texture whose dimensions have not changed with
  # texSubImage2D rather than texImage2D, so every bitmap redrawn after its
  # first upload arrives there — window contents, rendered text, a Bitmap the
  # game paints into — and rmmz's Tilemap fills its tile atlas by sub-uploading
  # each tileset page into a quadrant. The wrapper used to accept the call and
  # throw it away, which left all of those showing whatever the texture held on
  # its first upload (usually nothing).
  #
  # Upload a red 2x2 texture, overwrite it with green through texSubImage2D,
  # then sample it onto a full-viewport quad.
  out = MV::JS.eval(<<~'JS')
    (function () {
      var W = 32, H = 32;
      var cv = document.createElement('canvas'); cv.width = W; cv.height = H;
      var gl = cv.getContext('webgl');
      if (!gl) return 'no-context';
      function shader(type, src) {
        var s = gl.createShader(type);
        gl.shaderSource(s, src); gl.compileShader(s);
        return gl.getShaderParameter(s, gl.COMPILE_STATUS) ? s : null;
      }
      var vs = shader(gl.VERTEX_SHADER,
        '#version 100\nattribute vec2 aPos;\nvarying vec2 vUv;\n' +
        'void main(){ vUv = aPos * 0.5 + 0.5; gl_Position = vec4(aPos,0.0,1.0); }\n');
      var fs = shader(gl.FRAGMENT_SHADER,
        '#version 100\nprecision mediump float;\nvarying vec2 vUv;\n' +
        'uniform sampler2D uTex;\nvoid main(){ gl_FragColor = texture2D(uTex, vUv); }\n');
      if (!vs || !fs) return 'shader-failed';
      var p = gl.createProgram();
      gl.attachShader(p, vs); gl.attachShader(p, fs);
      gl.bindAttribLocation(p, 0, 'aPos');
      gl.linkProgram(p);
      if (!gl.getProgramParameter(p, gl.LINK_STATUS)) return 'link-failed';
      gl.useProgram(p);
      gl.viewport(0, 0, W, H);

      var red = new Uint8Array(2 * 2 * 4);
      var green = new Uint8Array(2 * 2 * 4);
      for (var i = 0; i < 4; i++) {
        red[i * 4] = 255; red[i * 4 + 3] = 255;
        green[i * 4 + 1] = 255; green[i * 4 + 3] = 255;
      }
      var tex = gl.createTexture();
      gl.bindTexture(gl.TEXTURE_2D, tex);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
      gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, 2, 2, 0, gl.RGBA, gl.UNSIGNED_BYTE, red);
      // The update under test: same size, so this is the call PIXI makes.
      gl.texSubImage2D(gl.TEXTURE_2D, 0, 0, 0, 2, 2, gl.RGBA, gl.UNSIGNED_BYTE, green);
      gl.uniform1i(gl.getUniformLocation(p, 'uTex'), 0);

      var view = new Float32Array([-1,-1, 1,-1, -1,1, 1,-1, 1,1, -1,1]);
      var buf = gl.createBuffer();
      gl.bindBuffer(gl.ARRAY_BUFFER, buf);
      gl.bufferData(gl.ARRAY_BUFFER, view, gl.STATIC_DRAW);
      gl.enableVertexAttribArray(0);
      gl.vertexAttribPointer(0, 2, gl.FLOAT, false, 0, 0);
      gl.clearColor(0.0, 0.0, 0.0, 1.0);
      gl.clear(gl.COLOR_BUFFER_BIT);
      gl.drawArrays(gl.TRIANGLES, 0, 6);
      gl.finish();

      var px = new Uint8Array(4);
      gl.readPixels(W / 2, H / 2, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, px);
      return px[0] + ',' + px[1] + ',' + px[2];
    })()
  JS

  assert_false ["no-context", "shader-failed", "link-failed"].include?(out)
  rgb = out.split(",").map { |v| v.to_i }
  assert_equal 3, rgb.size
  # Green means the sub-upload landed; red means it was dropped and the first
  # upload is all the texture ever got.
  assert_true rgb[1] > 200
  assert_true rgb[0] < 60
end

# --- M6.3c: UNPACK_PREMULTIPLY_ALPHA_WEBGL -----------------------------------
#
# PIXI sets `gl.pixelStorei(gl.UNPACK_PREMULTIPLY_ALPHA_WEBGL, ...)` on every
# ordinary texture upload (`libs/pixi.js` in a fetched MZ corescript, in
# `TextureSystem.updateTexture`/`RenderTextureSystem` etc.), true whenever a
# BaseTexture's `alphaMode` is the default `UNPACK` (= PREMULTIPLY_ON_UPLOAD,
# what every plain image resource gets) — and its NORMAL blend mode is
# `[gl.ONE, gl.ONE_MINUS_SRC_ALPHA]`, which assumes the source colour is
# already scaled by its own alpha. js_gl_pixel_storei used to swallow this
# enum entirely (real GLES has no equivalent), so every texture uploaded with
# straight alpha and every partially-transparent pixel — window corners,
# any anti-aliased sprite edge — blended over-bright. Unlike
# UNPACK_FLIP_Y_WEBGL (never set true by a stock PIXI v5 build, see
# js_gl_pixel_storei's comment), this one is live on the very first texture
# any real MZ game uploads.

assert 'UNPACK_PREMULTIPLY_ALPHA_WEBGL premultiplies a raw texImage2D upload' do
  skip 'EGL/GLES2 backend not compiled into this build' unless MV::GL.available?

  # A solid 1x1 half-alpha-red texture, sampled onto a full-viewport quad with
  # blending disabled so the read-back pixel is exactly what is in the
  # texture. Uploaded twice, once with the flag off (default) and once on;
  # only the second should come back scaled by its own alpha.
  out = MV::JS.eval(<<~'JS')
    (function () {
      var W = 8, H = 8;
      var cv = document.createElement('canvas'); cv.width = W; cv.height = H;
      var gl = cv.getContext('webgl');
      if (!gl) return 'no-context';
      function shader(type, src) {
        var s = gl.createShader(type);
        gl.shaderSource(s, src); gl.compileShader(s);
        return gl.getShaderParameter(s, gl.COMPILE_STATUS) ? s : null;
      }
      var vs = shader(gl.VERTEX_SHADER,
        '#version 100\nattribute vec2 aPos;\nvarying vec2 vUv;\n' +
        'void main(){ vUv = aPos * 0.5 + 0.5; gl_Position = vec4(aPos,0.0,1.0); }\n');
      var fs = shader(gl.FRAGMENT_SHADER,
        '#version 100\nprecision mediump float;\nvarying vec2 vUv;\n' +
        'uniform sampler2D uTex;\nvoid main(){ gl_FragColor = texture2D(uTex, vUv); }\n');
      if (!vs || !fs) return 'shader-failed';
      var p = gl.createProgram();
      gl.attachShader(p, vs); gl.attachShader(p, fs);
      gl.bindAttribLocation(p, 0, 'aPos');
      gl.linkProgram(p);
      if (!gl.getProgramParameter(p, gl.LINK_STATUS)) return 'link-failed';
      gl.useProgram(p);
      gl.viewport(0, 0, W, H);
      gl.disable(gl.BLEND);

      var quad = gl.createBuffer();
      gl.bindBuffer(gl.ARRAY_BUFFER, quad);
      gl.bufferData(gl.ARRAY_BUFFER,
        new Float32Array([-1,-1, 1,-1, -1,1, 1,-1, 1,1, -1,1]), gl.STATIC_DRAW);
      gl.enableVertexAttribArray(0);
      gl.vertexAttribPointer(0, 2, gl.FLOAT, false, 0, 0);
      gl.uniform1i(gl.getUniformLocation(p, 'uTex'), 0);

      function drawWith(premultiply) {
        var tex = gl.createTexture();
        gl.bindTexture(gl.TEXTURE_2D, tex);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
        gl.pixelStorei(gl.UNPACK_PREMULTIPLY_ALPHA_WEBGL, premultiply);
        gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, 1, 1, 0, gl.RGBA,
                      gl.UNSIGNED_BYTE, new Uint8Array([200, 0, 0, 128]));
        gl.pixelStorei(gl.UNPACK_PREMULTIPLY_ALPHA_WEBGL, false); // PIXI resets it
        gl.clearColor(0, 0, 0, 0);
        gl.clear(gl.COLOR_BUFFER_BIT);
        gl.drawArrays(gl.TRIANGLES, 0, 6);
        gl.finish();
        var px = new Uint8Array(4);
        gl.readPixels(W / 2, H / 2, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, px);
        gl.deleteTexture(tex);
        return px[0] + ':' + px[1] + ':' + px[2] + ':' + px[3];
      }

      return drawWith(false) + ' | ' + drawWith(true);
    })()
  JS

  assert_false ["no-context", "shader-failed", "link-failed"].include?(out)
  straight, premultiplied = out.split(" | ")
  assert_equal "200:0:0:128", straight # flag off (default): untouched
  s = premultiplied.split(":").map(&:to_i)
  assert_equal 4, s.size
  assert_true (s[0] - 100).abs <= 3 # 200 * 128 / 255 ~= 100.4
  assert_equal 0, s[1]
  assert_equal 0, s[2]
  assert_equal 128, s[3] # alpha itself is untouched, only colour is scaled
end

assert 'UNPACK_PREMULTIPLY_ALPHA_WEBGL premultiplies a texSubImage2D-from-canvas upload' do
  skip 'EGL/GLES2 backend not compiled into this build' unless MV::GL.available?

  # The path that actually carries MZ's pixels (see the texSubImage2D test
  # above): a Canvas2D source drawn with a fractional globalAlpha (so its
  # straight RGBA has a non-trivial, non-hardcoded alpha), sub-uploaded with
  # the flag on. The expected premultiplied colour is derived from the
  # canvas' own *measured* straight pixel rather than an assumed constant, so
  # this does not depend on the colour parser's own rounding.
  out = MV::JS.eval(<<~'JS')
    (function () {
      var W = 8, H = 8;
      var cv = document.createElement('canvas'); cv.width = W; cv.height = H;
      var gl = cv.getContext('webgl');
      if (!gl) return 'no-context';
      function shader(type, src) {
        var s = gl.createShader(type);
        gl.shaderSource(s, src); gl.compileShader(s);
        return gl.getShaderParameter(s, gl.COMPILE_STATUS) ? s : null;
      }
      var vs = shader(gl.VERTEX_SHADER,
        '#version 100\nattribute vec2 aPos;\nvarying vec2 vUv;\n' +
        'void main(){ vUv = aPos * 0.5 + 0.5; gl_Position = vec4(aPos,0.0,1.0); }\n');
      var fs = shader(gl.FRAGMENT_SHADER,
        '#version 100\nprecision mediump float;\nvarying vec2 vUv;\n' +
        'uniform sampler2D uTex;\nvoid main(){ gl_FragColor = texture2D(uTex, vUv); }\n');
      if (!vs || !fs) return 'shader-failed';
      var p = gl.createProgram();
      gl.attachShader(p, vs); gl.attachShader(p, fs);
      gl.bindAttribLocation(p, 0, 'aPos');
      gl.linkProgram(p);
      if (!gl.getProgramParameter(p, gl.LINK_STATUS)) return 'link-failed';
      gl.useProgram(p);
      gl.viewport(0, 0, W, H);
      gl.disable(gl.BLEND);

      var quad = gl.createBuffer();
      gl.bindBuffer(gl.ARRAY_BUFFER, quad);
      gl.bufferData(gl.ARRAY_BUFFER,
        new Float32Array([-1,-1, 1,-1, -1,1, 1,-1, 1,1, -1,1]), gl.STATIC_DRAW);
      gl.enableVertexAttribArray(0);
      gl.vertexAttribPointer(0, 2, gl.FLOAT, false, 0, 0);
      gl.uniform1i(gl.getUniformLocation(p, 'uTex'), 0);

      var srcCv = document.createElement('canvas'); srcCv.width = 1; srcCv.height = 1;
      var sctx = srcCv.getContext('2d');
      sctx.globalAlpha = 0.5;
      sctx.fillStyle = '#c80000';
      sctx.fillRect(0, 0, 1, 1);
      var truth = __mv_canvasGetPixel(srcCv.__h, 0, 0); // straight RGBA, measured

      var tex = gl.createTexture();
      gl.bindTexture(gl.TEXTURE_2D, tex);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
      gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, 1, 1, 0, gl.RGBA, gl.UNSIGNED_BYTE, null);
      gl.pixelStorei(gl.UNPACK_PREMULTIPLY_ALPHA_WEBGL, true);
      gl.texSubImage2D(gl.TEXTURE_2D, 0, 0, 0, gl.RGBA, gl.UNSIGNED_BYTE, srcCv);
      gl.pixelStorei(gl.UNPACK_PREMULTIPLY_ALPHA_WEBGL, false);

      gl.clearColor(0, 0, 0, 0);
      gl.clear(gl.COLOR_BUFFER_BIT);
      gl.drawArrays(gl.TRIANGLES, 0, 6);
      gl.finish();
      var px = new Uint8Array(4);
      gl.readPixels(W / 2, H / 2, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, px);
      return truth.join(':') + ' | ' + px[0] + ':' + px[1] + ':' + px[2] + ':' + px[3];
    })()
  JS

  assert_false ["no-context", "shader-failed", "link-failed"].include?(out)
  truth_s, got_s = out.split(" | ")
  truth = truth_s.split(":").map(&:to_i)
  got = got_s.split(":").map(&:to_i)
  assert_equal 4, truth.size
  assert_true truth[3] > 0 && truth[3] < 255 # the fixture really is partially transparent
  assert_true (got[0] - truth[0] * truth[3] / 255).abs <= 3
  assert_true (got[1] - truth[1] * truth[3] / 255).abs <= 3
  assert_true (got[2] - truth[2] * truth[3] / 255).abs <= 3
  assert_equal truth[3], got[3] # alpha itself is untouched
end

# --- UNPACK_FLIP_Y_WEBGL addendum --------------------------------------------
#
# Unlike UNPACK_PREMULTIPLY_ALPHA_WEBGL above, no real content this project has
# driven through the engine (including a full played-out battle against a real
# downloaded MZ release, data/EgoicAnswers) has ever been observed setting
# this `true` rather than leaving it at its already-default `false` -- a stock
# PIXI v5 build never sets it (see js_gl_pixel_storei's comment). It is
# implemented anyway: it is unambiguous, spec-mandated WebGL behaviour (row
# order is reversed on upload), not a guess, and the wrapper already applies
# the analogous CPU-side transform for UNPACK_PREMULTIPLY_ALPHA_WEBGL at the
# same four call sites (flip_y_rgba mirrors premultiply_rgba in mvwebgl.cxx).
# These two tests only prove the row-reversal itself works; they do not (and
# cannot, absent such content) prove any real game relies on it.

assert 'UNPACK_FLIP_Y_WEBGL reverses row order on a raw texImage2D upload' do
  skip 'EGL/GLES2 backend not compiled into this build' unless MV::GL.available?

  # A 1x2 texture whose two rows are solid, distinct colours, sampled onto a
  # full-viewport quad with NEAREST filtering so the bottom and top of the
  # viewport read back exactly one texel each. The assertions only check that
  # flipping swaps which texel lands at the bottom vs. the top -- not which
  # absolute GL row convention (top-down vs. bottom-up) applies -- so the test
  # does not depend on that convention either way.
  out = MV::JS.eval(<<~'JS')
    (function () {
      var W = 4, H = 8;
      var cv = document.createElement('canvas'); cv.width = W; cv.height = H;
      var gl = cv.getContext('webgl');
      if (!gl) return 'no-context';
      function shader(type, src) {
        var s = gl.createShader(type);
        gl.shaderSource(s, src); gl.compileShader(s);
        return gl.getShaderParameter(s, gl.COMPILE_STATUS) ? s : null;
      }
      var vs = shader(gl.VERTEX_SHADER,
        '#version 100\nattribute vec2 aPos;\nvarying vec2 vUv;\n' +
        'void main(){ vUv = aPos * 0.5 + 0.5; gl_Position = vec4(aPos,0.0,1.0); }\n');
      var fs = shader(gl.FRAGMENT_SHADER,
        '#version 100\nprecision mediump float;\nvarying vec2 vUv;\n' +
        'uniform sampler2D uTex;\nvoid main(){ gl_FragColor = texture2D(uTex, vUv); }\n');
      if (!vs || !fs) return 'shader-failed';
      var p = gl.createProgram();
      gl.attachShader(p, vs); gl.attachShader(p, fs);
      gl.bindAttribLocation(p, 0, 'aPos');
      gl.linkProgram(p);
      if (!gl.getProgramParameter(p, gl.LINK_STATUS)) return 'link-failed';
      gl.useProgram(p);
      gl.viewport(0, 0, W, H);
      gl.disable(gl.BLEND);

      var quad = gl.createBuffer();
      gl.bindBuffer(gl.ARRAY_BUFFER, quad);
      gl.bufferData(gl.ARRAY_BUFFER,
        new Float32Array([-1,-1, 1,-1, -1,1, 1,-1, 1,1, -1,1]), gl.STATIC_DRAW);
      gl.enableVertexAttribArray(0);
      gl.vertexAttribPointer(0, 2, gl.FLOAT, false, 0, 0);
      gl.uniform1i(gl.getUniformLocation(p, 'uTex'), 0);

      function drawWith(flip) {
        var tex = gl.createTexture();
        gl.bindTexture(gl.TEXTURE_2D, tex);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
        gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, flip);
        gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, 1, 2, 0, gl.RGBA,
                      gl.UNSIGNED_BYTE, new Uint8Array([
                        255, 0, 0, 255,  // row 0 (first in the buffer): red
                        0, 0, 255, 255,  // row 1 (last in the buffer): blue
                      ]));
        gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, false); // PIXI resets it
        gl.clearColor(0, 0, 0, 0);
        gl.clear(gl.COLOR_BUFFER_BIT);
        gl.drawArrays(gl.TRIANGLES, 0, 6);
        gl.finish();
        var bottom = new Uint8Array(4), top = new Uint8Array(4);
        gl.readPixels(0, 0, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, bottom);
        gl.readPixels(0, H - 1, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, top);
        gl.deleteTexture(tex);
        return bottom.join(',') + '/' + top.join(',');
      }

      return drawWith(false) + ' | ' + drawWith(true);
    })()
  JS

  assert_false ["no-context", "shader-failed", "link-failed"].include?(out)
  unflipped, flipped = out.split(" | ")
  unflipped_bottom, unflipped_top = unflipped.split("/")
  flipped_bottom, flipped_top = flipped.split("/")
  assert_true unflipped_bottom != unflipped_top # sanity: the two rows differ
  assert_equal unflipped_bottom, flipped_top    # flip reverses row order:
  assert_equal unflipped_top, flipped_bottom    # bottom<->top swap
end

assert 'UNPACK_FLIP_Y_WEBGL reverses row order on a texSubImage2D-from-canvas upload' do
  skip 'EGL/GLES2 backend not compiled into this build' unless MV::GL.available?

  # Same swap as the raw-upload test above, but through the canvas-source
  # overload (js_gl_tex_sub_image_2d_canvas) that carries most of MZ's actual
  # pixels (see the texSubImage2D test near the top of this file).
  out = MV::JS.eval(<<~'JS')
    (function () {
      var W = 4, H = 8;
      var cv = document.createElement('canvas'); cv.width = W; cv.height = H;
      var gl = cv.getContext('webgl');
      if (!gl) return 'no-context';
      function shader(type, src) {
        var s = gl.createShader(type);
        gl.shaderSource(s, src); gl.compileShader(s);
        return gl.getShaderParameter(s, gl.COMPILE_STATUS) ? s : null;
      }
      var vs = shader(gl.VERTEX_SHADER,
        '#version 100\nattribute vec2 aPos;\nvarying vec2 vUv;\n' +
        'void main(){ vUv = aPos * 0.5 + 0.5; gl_Position = vec4(aPos,0.0,1.0); }\n');
      var fs = shader(gl.FRAGMENT_SHADER,
        '#version 100\nprecision mediump float;\nvarying vec2 vUv;\n' +
        'uniform sampler2D uTex;\nvoid main(){ gl_FragColor = texture2D(uTex, vUv); }\n');
      if (!vs || !fs) return 'shader-failed';
      var p = gl.createProgram();
      gl.attachShader(p, vs); gl.attachShader(p, fs);
      gl.bindAttribLocation(p, 0, 'aPos');
      gl.linkProgram(p);
      if (!gl.getProgramParameter(p, gl.LINK_STATUS)) return 'link-failed';
      gl.useProgram(p);
      gl.viewport(0, 0, W, H);
      gl.disable(gl.BLEND);

      var quad = gl.createBuffer();
      gl.bindBuffer(gl.ARRAY_BUFFER, quad);
      gl.bufferData(gl.ARRAY_BUFFER,
        new Float32Array([-1,-1, 1,-1, -1,1, 1,-1, 1,1, -1,1]), gl.STATIC_DRAW);
      gl.enableVertexAttribArray(0);
      gl.vertexAttribPointer(0, 2, gl.FLOAT, false, 0, 0);
      gl.uniform1i(gl.getUniformLocation(p, 'uTex'), 0);

      // A 1x2 source canvas, top pixel red, bottom pixel blue.
      var srcCv = document.createElement('canvas'); srcCv.width = 1; srcCv.height = 2;
      var sctx = srcCv.getContext('2d');
      sctx.fillStyle = '#ff0000'; sctx.fillRect(0, 0, 1, 1);
      sctx.fillStyle = '#0000ff'; sctx.fillRect(0, 1, 1, 1);

      function drawWith(flip) {
        var tex = gl.createTexture();
        gl.bindTexture(gl.TEXTURE_2D, tex);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
        gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, 1, 2, 0, gl.RGBA, gl.UNSIGNED_BYTE, null);
        gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, flip);
        gl.texSubImage2D(gl.TEXTURE_2D, 0, 0, 0, gl.RGBA, gl.UNSIGNED_BYTE, srcCv);
        gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, false);
        gl.clearColor(0, 0, 0, 0);
        gl.clear(gl.COLOR_BUFFER_BIT);
        gl.drawArrays(gl.TRIANGLES, 0, 6);
        gl.finish();
        var bottom = new Uint8Array(4), top = new Uint8Array(4);
        gl.readPixels(0, 0, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, bottom);
        gl.readPixels(0, H - 1, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, top);
        gl.deleteTexture(tex);
        return bottom.join(',') + '/' + top.join(',');
      }

      return drawWith(false) + ' | ' + drawWith(true);
    })()
  JS

  assert_false ["no-context", "shader-failed", "link-failed"].include?(out)
  unflipped, flipped = out.split(" | ")
  unflipped_bottom, unflipped_top = unflipped.split("/")
  flipped_bottom, flipped_top = flipped.split("/")
  assert_true unflipped_bottom != unflipped_top # sanity: the two rows differ
  assert_equal unflipped_bottom, flipped_top    # flip reverses row order:
  assert_equal unflipped_top, flipped_bottom    # bottom<->top swap
end

assert 'the stencil test masks inside a render texture, where MZ actually draws' do
  skip 'EGL/GLES2 backend not compiled into this build' unless MV::GL.available?

  # The masking test above works on the main FBO, which mvgl.cxx builds with its
  # own packed DEPTH24_STENCIL8 buffer. MZ never draws a scene there: every
  # `Scene_Base` carries a `ColorFilter`, so the scene renders into a *filter
  # render texture* and only the filter's output quad reaches the main FBO.
  # rmmz's `WindowLayer.render` asks PIXI for a stencil on whatever framebuffer
  # is current (`renderer.framebuffer.forceStencil()` -> createRenderbuffer +
  # renderbufferStorage(DEPTH_STENCIL) + framebufferRenderbuffer) and masks each
  # window against the ones in front of it. While those three were stubs no
  # attachment existed, the stencil test always passed, and every window
  # overpainted its neighbours.
  #
  # Same shape as the FBO test, but bound to a framebuffer whose colour target
  # is a texture and whose depth/stencil is a renderbuffer. Returns
  # "status,left,right".
  out = MV::JS.eval(<<~'JS')
    (function () {
      var W = 64, H = 64;
      var cv = document.createElement('canvas'); cv.width = W; cv.height = H;
      var gl = cv.getContext('webgl');
      if (!gl) return 'no-context';
      function shader(type, src) {
        var s = gl.createShader(type);
        gl.shaderSource(s, src); gl.compileShader(s);
        return gl.getShaderParameter(s, gl.COMPILE_STATUS) ? s : null;
      }
      var vs = shader(gl.VERTEX_SHADER,
        '#version 100\nattribute vec2 aPos;\nvoid main(){ gl_Position = vec4(aPos,0.0,1.0); }\n');
      var fs = shader(gl.FRAGMENT_SHADER,
        '#version 100\nprecision mediump float;\nuniform vec4 uCol;\nvoid main(){ gl_FragColor = uCol; }\n');
      if (!vs || !fs) return 'shader-failed';
      var p = gl.createProgram();
      gl.attachShader(p, vs); gl.attachShader(p, fs);
      gl.bindAttribLocation(p, 0, 'aPos');
      gl.linkProgram(p);
      if (!gl.getProgramParameter(p, gl.LINK_STATUS)) return 'link-failed';
      gl.useProgram(p);
      var uCol = gl.getUniformLocation(p, 'uCol');

      // A render texture, the way PIXI builds one for a filter pass...
      var tex = gl.createTexture();
      gl.bindTexture(gl.TEXTURE_2D, tex);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
      gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, W, H, 0, gl.RGBA, gl.UNSIGNED_BYTE, null);
      var fbo = gl.createFramebuffer();
      gl.bindFramebuffer(gl.FRAMEBUFFER, fbo);
      gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, tex, 0);
      // ...plus the stencil forceStencil() attaches. The combined WebGL1 enums
      // (DEPTH_STENCIL / DEPTH_STENCIL_ATTACHMENT) are what PIXI passes.
      var rb = gl.createRenderbuffer();
      gl.bindRenderbuffer(gl.RENDERBUFFER, rb);
      gl.renderbufferStorage(gl.RENDERBUFFER, gl.DEPTH_STENCIL, W, H);
      gl.framebufferRenderbuffer(gl.FRAMEBUFFER, gl.DEPTH_STENCIL_ATTACHMENT, gl.RENDERBUFFER, rb);
      var status = gl.checkFramebufferStatus(gl.FRAMEBUFFER);
      if (status !== gl.FRAMEBUFFER_COMPLETE) return 'fbo-' + status;

      gl.viewport(0, 0, W, H);
      var buf = gl.createBuffer();
      gl.bindBuffer(gl.ARRAY_BUFFER, buf);
      gl.enableVertexAttribArray(0);
      gl.vertexAttribPointer(0, 2, gl.FLOAT, false, 0, 0);
      function quad(x0, x1) {
        gl.bufferData(gl.ARRAY_BUFFER,
          new Float32Array([x0,-1, x1,-1, x0,1, x1,-1, x1,1, x0,1]), gl.STATIC_DRAW);
        gl.drawArrays(gl.TRIANGLES, 0, 6);
      }

      gl.clearColor(0.0, 0.0, 0.0, 1.0);
      gl.clearStencil(0);
      gl.clear(gl.COLOR_BUFFER_BIT | gl.STENCIL_BUFFER_BIT);
      gl.enable(gl.STENCIL_TEST);
      gl.stencilMask(0xff);
      gl.stencilFunc(gl.ALWAYS, 1, 0xff);
      gl.stencilOp(gl.KEEP, gl.KEEP, gl.REPLACE);
      gl.uniform4f(uCol, 0.0, 0.0, 0.0, 1.0);
      quad(-1.0, 0.0);                       // stamp the left half
      gl.stencilFunc(gl.EQUAL, 0, 0xff);
      gl.stencilOp(gl.KEEP, gl.KEEP, gl.KEEP);
      gl.uniform4f(uCol, 0.0, 1.0, 0.0, 1.0);
      quad(-1.0, 1.0);                       // green, only where unstamped
      gl.finish();

      var l = new Uint8Array(4), r = new Uint8Array(4);
      gl.readPixels(W / 4, H / 2, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, l);
      gl.readPixels(W * 3 / 4, H / 2, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, r);
      gl.disable(gl.STENCIL_TEST);
      gl.bindFramebuffer(gl.FRAMEBUFFER, null);
      return 'ok,' + l[1] + ',' + r[1];
    })()
  JS

  parts = out.split(",")
  # A framebuffer that never got its renderbuffer reports itself here rather
  # than as a confusing colour comparison.
  assert_equal "ok", parts[0]
  assert_equal 3, parts.size
  assert_true parts[2].to_i > 200 # right: drawn
  assert_true parts[1].to_i < 60  # left: masked out
end

# --- M6.3c fast path: OES_vertex_array_object / ANGLE_instanced_arrays ------
#
# PIXI's GeometrySystem.contextChange (libs/pixi.js in a fetched MZ
# corescript) checks `gl.createVertexArray`/`gl.vertexAttribDivisor` (WebGL2)
# first and, missing those, asks `getExtension` for these two by name and
# calls their ANGLE/OES-suffixed methods. `getExtension` used to always
# return null, so every draw went through PIXI's no-VAO/no-instancing
# fallback -- correct but slower. These prove the extension objects are real
# and functionally correct, not just present.

assert 'getExtension advertises OES_vertex_array_object / ANGLE_instanced_arrays / OES_element_index_uint with working methods, cached per call' do
  skip 'EGL/GLES2 backend not compiled into this build' unless MV::GL.available?

  # OES_element_index_uint has no methods (see the native-side comment above
  # js_gl_ext_vao_available) -- it is a pure capability flag PIXI reads once
  # into `context.extensions.uint32ElementIndex` and never calls anything on,
  # so this only checks it is present, non-null and cached, not any method.
  out = MV::JS.eval(<<~'JS')
    (function () {
      var cv = document.createElement('canvas'); cv.width = 4; cv.height = 4;
      var gl = cv.getContext('webgl');
      var supported = gl.getSupportedExtensions();
      var vao1 = gl.getExtension('OES_vertex_array_object');
      var vao2 = gl.getExtension('OES_vertex_array_object');
      var inst1 = gl.getExtension('ANGLE_instanced_arrays');
      var inst2 = gl.getExtension('ANGLE_instanced_arrays');
      var idx1 = gl.getExtension('OES_element_index_uint');
      var idx2 = gl.getExtension('OES_element_index_uint');
      var bogus = gl.getExtension('NOT_A_REAL_EXTENSION');
      var flags = [
        supported.indexOf('OES_vertex_array_object') >= 0,
        supported.indexOf('ANGLE_instanced_arrays') >= 0,
        supported.indexOf('OES_element_index_uint') >= 0,
        !!vao1,
        vao1 === vao2,
        typeof vao1.createVertexArrayOES === 'function',
        typeof vao1.bindVertexArrayOES === 'function',
        typeof vao1.deleteVertexArrayOES === 'function',
        typeof vao1.isVertexArrayOES === 'function',
        !!inst1,
        inst1 === inst2,
        typeof inst1.vertexAttribDivisorANGLE === 'function',
        typeof inst1.drawArraysInstancedANGLE === 'function',
        typeof inst1.drawElementsInstancedANGLE === 'function',
        !!idx1,
        idx1 === idx2,
        bogus === null,
      ];
      return flags.map(function (f) { return f ? 1 : 0; }).join(',');
    })()
  JS
  flags = out.split(",").map(&:to_i)
  assert_equal 17, flags.size
  flags.each_with_index { |f, i| assert_equal 1, f, "flag #{i}" }
end

assert 'a Uint32Array element index buffer draws correctly (OES_element_index_uint)' do
  skip 'EGL/GLES2 backend not compiled into this build' unless MV::GL.available?

  # The actual capability the flag stands for: PIXI only switches its index
  # buffer to Uint32Array (instead of splitting into multiple Uint16Array
  # batches) once this reads true, so what matters is that UNSIGNED_INT
  # indices really do draw correctly -- not just that the flag is set. A
  # full-viewport quad indexed with Uint32Array values, including one large
  # enough to overflow a Uint16Array (65536+).
  out = MV::JS.eval(<<~'JS')
    (function () {
      var W = 16, H = 16;
      var cv = document.createElement('canvas'); cv.width = W; cv.height = H;
      var gl = cv.getContext('webgl');
      if (!gl) return 'no-context';
      function shader(type, src) {
        var s = gl.createShader(type);
        gl.shaderSource(s, src); gl.compileShader(s);
        return gl.getShaderParameter(s, gl.COMPILE_STATUS) ? s : null;
      }
      var vs = shader(gl.VERTEX_SHADER,
        '#version 100\nattribute vec2 aPos;\nvoid main(){ gl_Position = vec4(aPos,0.0,1.0); }\n');
      var fs = shader(gl.FRAGMENT_SHADER,
        '#version 100\nprecision mediump float;\nvoid main(){ gl_FragColor = vec4(0.0,1.0,0.0,1.0); }\n');
      if (!vs || !fs) return 'shader-failed';
      var p = gl.createProgram();
      gl.attachShader(p, vs); gl.attachShader(p, fs);
      gl.bindAttribLocation(p, 0, 'aPos');
      gl.linkProgram(p);
      if (!gl.getProgramParameter(p, gl.LINK_STATUS)) return 'link-failed';
      gl.useProgram(p);
      gl.viewport(0, 0, W, H);
      gl.clearColor(0.0, 0.0, 0.0, 1.0);
      gl.clear(gl.COLOR_BUFFER_BIT);

      // Vertex 70000 is padding, unreferenced by any index -- only there so
      // a real 16-bit index buffer could not represent index 3 (the actual
      // last quad corner) without wrapping/corrupting.
      var verts = new Float32Array((70001) * 2);
      verts[0 * 2] = -1; verts[0 * 2 + 1] = -1;
      verts[1 * 2] = 1;  verts[1 * 2 + 1] = -1;
      verts[2 * 2] = -1; verts[2 * 2 + 1] = 1;
      verts[3 * 2] = 1;  verts[3 * 2 + 1] = 1;
      verts[70000 * 2] = 0; verts[70000 * 2 + 1] = 0;

      var vbuf = gl.createBuffer();
      gl.bindBuffer(gl.ARRAY_BUFFER, vbuf);
      gl.bufferData(gl.ARRAY_BUFFER, verts, gl.STATIC_DRAW);
      gl.enableVertexAttribArray(0);
      gl.vertexAttribPointer(0, 2, gl.FLOAT, false, 0, 0);

      var idx = new Uint32Array([0, 1, 2, 1, 3, 2, 70000]);
      var ibuf = gl.createBuffer();
      gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER, ibuf);
      gl.bufferData(gl.ELEMENT_ARRAY_BUFFER, idx, gl.STATIC_DRAW);

      gl.drawElements(gl.TRIANGLES, 6, gl.UNSIGNED_INT, 0);
      gl.finish();
      var err = gl.getError();

      var px = new Uint8Array(4);
      gl.readPixels(W / 2, H / 2, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, px);
      return err + ',' + px[0] + ',' + px[1] + ',' + px[2];
    })()
  JS

  assert_false ["no-context", "shader-failed", "link-failed"].include?(out)
  parts = out.split(",")
  assert_equal 4, parts.size
  assert_equal "0", parts[0] # GL_NO_ERROR
  assert_true parts[2].to_i > 200 # green: the UNSIGNED_INT-indexed quad drew
  assert_true parts[1].to_i < 60
end

assert 'a VAO round-trips vertex attribute state (OES_vertex_array_object)' do
  skip 'EGL/GLES2 backend not compiled into this build' unless MV::GL.available?

  # VAO A binds a full-screen (overflowing) triangle to attribute 0; VAO B
  # never sets up attribute 0 at all. Drawing through each with the *same*
  # program/draw call must produce different pixels only if the buffer
  # binding, enable state and vertexAttribPointer really are captured and
  # restored per-VAO rather than living in shared context state.
  out = MV::JS.eval(<<~'JS')
    (function () {
      var W = 64, H = 64;
      var cv = document.createElement('canvas'); cv.width = W; cv.height = H;
      var gl = cv.getContext('webgl');
      if (!gl) return 'no-context';
      var vaoExt = gl.getExtension('OES_vertex_array_object');
      if (!vaoExt) return 'no-vao-ext';

      var vs = gl.createShader(gl.VERTEX_SHADER);
      gl.shaderSource(vs, '#version 100\nattribute vec2 aPos;\nvoid main(){ gl_Position = vec4(aPos,0.0,1.0); }\n');
      gl.compileShader(vs);
      var fs = gl.createShader(gl.FRAGMENT_SHADER);
      gl.shaderSource(fs, '#version 100\nprecision mediump float;\nvoid main(){ gl_FragColor = vec4(0.0,1.0,0.0,1.0); }\n');
      gl.compileShader(fs);
      var p = gl.createProgram();
      gl.attachShader(p, vs); gl.attachShader(p, fs);
      gl.bindAttribLocation(p, 0, 'aPos');
      gl.linkProgram(p);
      if (!gl.getProgramParameter(p, gl.LINK_STATUS)) return 'link-failed';
      gl.useProgram(p);
      gl.viewport(0, 0, W, H);

      var vaoA = vaoExt.createVertexArrayOES();
      vaoExt.bindVertexArrayOES(vaoA);
      var bufA = gl.createBuffer();
      gl.bindBuffer(gl.ARRAY_BUFFER, bufA);
      gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1,-1, 3,-1, -1,3]), gl.STATIC_DRAW);
      gl.enableVertexAttribArray(0);
      gl.vertexAttribPointer(0, 2, gl.FLOAT, false, 0, 0);

      // VAO B: created and bound, but attribute 0 is left disabled -- its
      // "current value" defaults to (0,0,0,1) for every vertex, collapsing
      // the triangle to a single point (nothing rasterises).
      var vaoB = vaoExt.createVertexArrayOES();
      vaoExt.bindVertexArrayOES(vaoB);
      vaoExt.bindVertexArrayOES(null);

      function draw(vao) {
        gl.clearColor(0.6, 0.0, 0.0, 1.0);
        gl.clear(gl.COLOR_BUFFER_BIT);
        vaoExt.bindVertexArrayOES(vao);
        gl.drawArrays(gl.TRIANGLES, 0, 3);
        gl.finish();
        var px = new Uint8Array(4);
        gl.readPixels(W / 2, H / 2, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, px);
        return px[1];
      }

      var greenA = draw(vaoA);
      var greenB = draw(vaoB);
      var wasVaoA = vaoExt.isVertexArrayOES(vaoA);
      vaoExt.deleteVertexArrayOES(vaoA);
      vaoExt.deleteVertexArrayOES(vaoB);
      var isVaoAAfterDelete = vaoExt.isVertexArrayOES(vaoA);
      return [greenA, greenB, wasVaoA ? 1 : 0, isVaoAAfterDelete ? 1 : 0].join(',');
    })()
  JS
  parts = out.split(",")
  assert_equal 4, parts.size
  assert_true parts[0].to_i > 200 # VAO A: its own attribute state draws green
  assert_true parts[1].to_i < 60  # VAO B: no attribute 0 set up, nothing drawn
  assert_equal "1", parts[2]      # isVertexArrayOES true for a live VAO
  assert_equal "0", parts[3]      # ...and false once deleted
end

assert 'drawArraysInstancedANGLE draws one primitive per instance at its own offset (ANGLE_instanced_arrays)' do
  skip 'EGL/GLES2 backend not compiled into this build' unless MV::GL.available?

  # A per-vertex triangle big enough to fully cover a small square around the
  # origin (the same "overflowing triangle" trick as the plain smoke test,
  # scaled down), offset per-instance by a divisor-1 attribute. Two instances,
  # at -0.5 and +0.5 on the x axis, must each paint their own small square and
  # leave the gap between them (and everywhere else) untouched -- proof this
  # is really two separate instanced draws and not one shape spanning both.
  out = MV::JS.eval(<<~'JS')
    (function () {
      var W = 64, H = 64;
      var cv = document.createElement('canvas'); cv.width = W; cv.height = H;
      var gl = cv.getContext('webgl');
      if (!gl) return 'no-context';
      var instExt = gl.getExtension('ANGLE_instanced_arrays');
      if (!instExt) return 'no-instance-ext';

      var vs = gl.createShader(gl.VERTEX_SHADER);
      gl.shaderSource(vs,
        '#version 100\nattribute vec2 aPos;\nattribute vec2 aOffset;\n' +
        'void main(){ gl_Position = vec4(aPos * 0.15 + aOffset,0.0,1.0); }\n');
      gl.compileShader(vs);
      if (!gl.getShaderParameter(vs, gl.COMPILE_STATUS)) return 'vs-failed';
      var fs = gl.createShader(gl.FRAGMENT_SHADER);
      gl.shaderSource(fs, '#version 100\nprecision mediump float;\nvoid main(){ gl_FragColor = vec4(0.0,1.0,0.0,1.0); }\n');
      gl.compileShader(fs);
      var p = gl.createProgram();
      gl.attachShader(p, vs); gl.attachShader(p, fs);
      gl.bindAttribLocation(p, 0, 'aPos');
      gl.bindAttribLocation(p, 1, 'aOffset');
      gl.linkProgram(p);
      if (!gl.getProgramParameter(p, gl.LINK_STATUS)) return 'link-failed';
      gl.useProgram(p);
      gl.viewport(0, 0, W, H);
      gl.clearColor(0.6, 0.0, 0.0, 1.0);
      gl.clear(gl.COLOR_BUFFER_BIT);

      var posBuf = gl.createBuffer();
      gl.bindBuffer(gl.ARRAY_BUFFER, posBuf);
      gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1,-1, 3,-1, -1,3]), gl.STATIC_DRAW);
      gl.enableVertexAttribArray(0);
      gl.vertexAttribPointer(0, 2, gl.FLOAT, false, 0, 0);

      var offBuf = gl.createBuffer();
      gl.bindBuffer(gl.ARRAY_BUFFER, offBuf);
      gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-0.5,0, 0.5,0]), gl.STATIC_DRAW);
      gl.enableVertexAttribArray(1);
      gl.vertexAttribPointer(1, 2, gl.FLOAT, false, 0, 0);
      instExt.vertexAttribDivisorANGLE(1, 1);

      instExt.drawArraysInstancedANGLE(gl.TRIANGLES, 0, 3, 2);
      gl.finish();

      function px(x, y) {
        var out = new Uint8Array(4);
        gl.readPixels(x, y, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, out);
        return out[1];
      }
      return [px(16, 32), px(32, 32), px(48, 32)].join(',');
    })()
  JS
  parts = out.split(",")
  assert_equal 3, parts.size
  assert_true parts[0].to_i > 200 # left instance (offset -0.5): drawn
  assert_true parts[1].to_i < 60  # midpoint between them: untouched
  assert_true parts[2].to_i > 200 # right instance (offset +0.5): drawn
end

# --- MV (not just MZ) presenting a WebGL frame ------------------------------
#
# mvwebgl.cxx installs canvas.getContext('webgl') globally, for every maker --
# not only MZ. rpg_core.js's `Graphics._rendererType` defaults to `'auto'`,
# and PIXI.autoDetectRenderer picks WebGLRenderer whenever that call succeeds,
# which it now always does; a plain MV game (PIXI v4) therefore renders
# through WebGL exactly like MZ (PIXI v5) does. MV#present/#maybe_screenshot
# (mv.rb) predate the WebGL wrapper and still read the plain Canvas2D buffer
# WebGLRenderer never touches, so every MV game rendered as a blank screen the
# moment mvwebgl.cxx landed -- found by actually running data/Lunatic-Core (a
# real downloaded MV game) and finding every captured frame blank white,
# despite `[MV-MOVE] moved=true` and friends all reporting success (they check
# only game *state*, never what the screen shows). Fixed by giving MV its own
# `#mv_gl_handle` (mirrors MZ's `#mz_gl_handle`) and branching #present and
# #maybe_screenshot on it exactly like mz.rb already does -- these two tests
# fake just enough of MV's own `Graphics` global (`_renderer.gl`, the MV
# equivalent of MZ's `Graphics._app.renderer.gl`) to exercise that resolution
# and the present path without needing a full corescript boot.
def cleanup_fake_graphics
  MV::JS.eval("delete globalThis.Graphics;")
end

assert 'MV#mv_gl_handle resolves the handle from Graphics._renderer.gl' do
  skip 'EGL/GLES2 backend not compiled into this build' unless MV::GL.available?

  handle = MV::JS.eval(<<~'JS').to_i
    (function () {
      var cv = document.createElement('canvas'); cv.width = 4; cv.height = 4;
      var gl = cv.getContext('webgl');
      if (!gl) return 0;
      globalThis.Graphics = { _renderer: { gl: gl } };
      return gl.__gl;
    })();
  JS
  assert_true handle > 0

  resolved = MV.allocate.send(:mv_gl_handle)
  assert_equal handle, resolved
ensure
  cleanup_fake_graphics
end

assert 'MV#present reads the real WebGL frame once Graphics._renderer.gl resolves' do
  skip 'EGL/GLES2 backend not compiled into this build' unless MV::GL.available?

  out = MV::JS.eval(<<~'JS')
    (function () {
      var cv = document.createElement('canvas'); cv.width = 8; cv.height = 8;
      var gl = cv.getContext('webgl');
      if (!gl) return 'no-context';
      gl.viewport(0, 0, 8, 8);
      gl.clearColor(0, 1, 0, 1);
      gl.clear(gl.COLOR_BUFFER_BIT);
      gl.finish();
      globalThis.Graphics = { _renderer: { gl: gl } };
      return 'ok';
    })()
  JS
  assert_equal 'ok', out

  mv = MV.allocate
  bmp = RGSS::Bitmap.new(8, 8)
  mv.instance_variable_set(:@screen_bitmap, bmp)
  mv.send(:present)

  c = bmp.get_pixel(4, 4)
  assert_true c.green > 200 # the cleared green frame, read back off the FBO
  assert_true c.red < 60    # not the plain Canvas2D buffer (untouched, blank)
  assert_true c.blue < 60
ensure
  cleanup_fake_graphics
end
