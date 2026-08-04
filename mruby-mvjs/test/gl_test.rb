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
