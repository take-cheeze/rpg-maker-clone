- **bc2cpp** rejects a subclass initializer that omits `super` when its base
  embeds ivars. Embedded storage is retained only when initialization reaches
  the base first; unproven initializer order uses mruby's ivar table instead.
