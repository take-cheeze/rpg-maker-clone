- **bc2cpp**: the generated embedded-struct free-er now tolerates a null
  payload (`if (!p) return;` before the placement destructor). mruby tests
  `d->type && d->type->dfree` but never `d->data` (`3rd/mruby/src/gc.c`), so
  this runs with a null pointer whenever an object's `#initialize` raised
  before its `mrb_data_init` -- a compiled `#initialize` is a `MRB_TT_DATA`
  shell with `data == NULL` until its own allocation runs. `mrb_free(NULL)`
  was harmless; `static_cast<T*>(nullptr)->~T()` is UB as soon as the
  destructor is non-trivial, which is exactly the case the non-POD destructor
  support exists to enable. Verified against the real `libmruby_core.a`: 1000
  bare `MRB_TT_DATA` shells produced 1000 dfree calls with `p == NULL`, every
  one of them at `mrb_close`. Same guard the hand-written
  `DataType<T>::free_obj` already uses (`mruby-rgss/src/lib.cxx`).
