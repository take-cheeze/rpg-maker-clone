- **bc2cpp** compiles `Fiber.new` bodies into a C++ Fiber (`resume`, `transfer`, `Fiber.yield`, `Fiber.current`, `Fiber#raise`) that can suspend through compiled methods, blocks, closures, keyword/optional/rest parameters and `rescue`/`ensure`/`retry`, and runs `Enumerator#next` on it (`BC2CPP_ENUMERATOR_FIBER=0` opts out).
  See `docs/bc2cpp-cxx-fiber.md` for the limits.
