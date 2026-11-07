- **bc2cpp** C++ Fiber: methods with keyword parameters (alone, or next to optional, rest and block parameters) are
  resumable steps, and calls that carry keywords (`send`, `public_send`, a call on self) bind them with the interpreter's
  ArgumentErrors. The `custom nested each` and `nested ensure` native-Fiber scenarios no longer differ from interpreted mruby.
