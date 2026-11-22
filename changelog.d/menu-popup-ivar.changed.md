- **bc2cpp (Wio Terminal):** Scene::Menu's popup message lives in `@popup`, so Scene::Map's `@message` is proven nil or
  a MessageState and 92 of its owner-class guards and NoMethodError fallbacks become nil tests.
