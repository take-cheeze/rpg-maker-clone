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
