- MZ: `OES_element_index_uint` is now advertised, so PIXI stops capping every
  index buffer at 65536 vertices (`Uint16Array`) and splitting draws into more
  batches than necessary. Unlike `OES_vertex_array_object`/
  `ANGLE_instanced_arrays` this needs no native entry points — it has no
  methods, and the software WebGL backend is GLES 3.0+ core throughout, where
  `UNSIGNED_INT` indices are unconditionally legal — so it is a pure always-on
  capability flag. Found by booting a real freem.ne.jp MZ release, which
  logged `Provided WebGL context does not support 32 index buffer` on boot.
