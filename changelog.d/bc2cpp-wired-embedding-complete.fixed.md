- The desktop `RPGMAKER_BC2CPP` build no longer embeds `Game::Interpreter`,
  `Game::Transition` or `Game::Map`. Each has compiled entry points the
  hand-written `register.cxx` never installs (25, 4 and 2), so an interpreted
  fallback read the ordinary ivar table while compiled methods wrote the
  embedded struct and saw nil. The visible symptom was `nil >= x` inside
  `Scene::Map#step_parallel`, swallowed by its `rescue StandardError` on every
  frame, which left every Parallel Process (and ~250 NoMethodError allocations
  a second) dead. New `scripts/bc2cpp_wired_embedding_check.rb` fails when a
  class in `BC2CPP_WIRED_EMBEDDINGS` has a compiled entry point that its
  `register.cxx` does not install.
