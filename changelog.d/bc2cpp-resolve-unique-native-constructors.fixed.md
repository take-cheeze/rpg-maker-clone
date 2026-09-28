- bc2cpp now resolves bare native constructor constants through the closed
  world's unique, lexically reachable class proof, enabling direct `new`
  lowering for names such as `Bitmap` without guessing across constants.
