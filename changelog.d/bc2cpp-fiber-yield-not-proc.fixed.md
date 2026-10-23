- The Fiber yield analysis no longer treats `Fiber.yield` as a possible Proc
  call. Each such site had widened the set of methods a Fiber may cross to
  every escaped Proc.
