- bc2cpp's `OP_EQ` fallback now uses the same MONO/TYPED resolver as the other
  comparison operators and stores the `==` method's own result (as the VM's
  `OP_CMP` does), and answers a non-identical Symbol receiver `false` without a
  send, matching `OP_EQ`.
