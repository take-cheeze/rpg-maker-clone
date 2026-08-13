- MZ: PIXI's fast geometry path (`OES_vertex_array_object`,
  `ANGLE_instanced_arrays`) now works instead of always falling back to
  PIXI's own no-VAO/no-instancing path — `getExtension` used to return `null`
  unconditionally. Both are now real extension objects backed by the GLES 3.0
  core functions the software (llvmpipe) driver actually implements, loaded
  via `eglGetProcAddress`. The legacy `ANGLE`-suffixed entry points resolve to
  a non-null pointer too (an implementation may hand back a pointer for a
  name it does not support) but silently drew nothing, so the loader now
  tries the core name first and falls back to the OES/ANGLE-suffixed name
  only for a driver with no core entry points at all.
