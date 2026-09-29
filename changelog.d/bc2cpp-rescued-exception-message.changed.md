- bc2cpp emits the core exception-message operation directly when the receiver
  is proven to be the rescued exception and no Ruby override can intercept it.
