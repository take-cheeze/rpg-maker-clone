- bc2cpp resolves explicitly qualified constructor constants from their full
  constant path, allowing proven compiled initializers to use direct construction
  inside nested lexical scopes. `Array.new`, `Hash.new` and `Range.new` use
  guarded `mrb_obj_new` when the closed-world proof confirms standard constructor
  lookup.
