bc2cpp: without mruby-fiber, `Fiber.current` at the root is a Fiber object of the C++ runtime (alive, inspectable), and `transfer` to it from a compiled fiber is the same yield as with mruby-fiber.
