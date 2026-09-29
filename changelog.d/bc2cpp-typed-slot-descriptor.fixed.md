- bc2cpp RData ivar descriptors list only mrb_value slots and a typed ivar
  that an interpreted method touches stays a plain slot, so GC marking and
  mrb_iv_get no longer misread raw C fields (segfault in the optcarrot probe).
